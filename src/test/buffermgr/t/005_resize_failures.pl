# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Test that pg_resize_shared_buffers() rolls back cleanly when resize fails.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $have_injection_points = ($ENV{enable_injection_points} eq 'yes');

# Start the pool large enough that there is room to shrink below a pinned
# buffer while still satisfying the shared_buffers GUC minimum.
my $initial_nbuffers = 24;
my $max_nbuffers = 32;
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
if ($have_injection_points)
{
	$node->append_conf('postgresql.conf', 'shared_preload_libraries = injection_points');
}
$node->append_conf('postgresql.conf', "shared_buffers = $initial_nbuffers");
$node->append_conf('postgresql.conf', "max_shared_buffers = $max_nbuffers");
$node->start;

# pg_buffercache lets us locate the bufferid holding a given page.
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");
if ($have_injection_points)
{
	$node->safe_psql('postgres', "CREATE EXTENSION injection_points");
}

# ---------------------------------------------------------------------------
# Test the case when shrinking is aborted by a pinned buffer
# ---------------------------------------------------------------------------

my $min_nbuffers = $node->safe_psql('postgres',
	"SELECT min_val::int FROM pg_settings WHERE name = 'shared_buffers'");

# In order to reliably pin a buffer above $min_nbuffers, we create as many
# tables $min_nbuffers + 1, open a cursor on the tables and fetch one row from
# each cursor one at a time.  This will pin one buffer per table, guaranteeing
# that at least one of the pinned buffers will be above $min_nbuffers.
my $ntables = $min_nbuffers + 1;
for my $i (1 .. $ntables)
{
	$node->safe_psql('postgres', "CREATE TABLE evict_target_$i AS SELECT generate_series(1, 2) AS i");
}
my $pinner = $node->background_psql('postgres', on_error_stop => 0);
$pinner->query_safe("BEGIN", verbose => 0);
my $pinned_buf = 0;
for my $i (1 .. $ntables)
{
	$pinner->query_safe("DECLARE c_$i CURSOR FOR SELECT * FROM evict_target_$i", verbose => 0);
	$pinner->query_safe("FETCH 1 FROM c_$i", verbose => 0);

	my $buf = $node->safe_psql('postgres',
    "SELECT min(bufferid) FROM pg_buffercache WHERE pinning_backends > 0 AND bufferid > $min_nbuffers");

	if ($buf =~ /^\d+$/)
	{
		$pinned_buf = $buf;
		last;
	}
}
cmp_ok($pinned_buf, '>', $min_nbuffers, "pinned a buffer above $min_nbuffers");

# Set the target so that the pinned buffer is in the range of buffers to be evicted.
my $shrink_target = $pinned_buf - 1;
$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$shrink_target'");
$node->safe_psql('postgres', "SELECT pg_reload_conf()");

my $log_offset = -s $node->logfile;

is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"),
	'f',
	"shrink returns false when a buffer to be evicted is pinned");
ok($node->log_contains(qr/could not remove buffer $pinned_buf, it is pinned/, $log_offset),
	"log reports the pinned buffer that blocked eviction");
ok($node->log_contains(qr/failed to evict extra buffers during shrinking/, $log_offset),
	"log reports the eviction failure");

is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
	"$initial_nbuffers|$initial_nbuffers|$initial_nbuffers|0",
	"pool unchanged after eviction failure");

is($node->safe_psql('postgres',
		"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
	"$initial_nbuffers (pending: $shrink_target)",
	"pg_settings reports pending shrink target");

# Releasing all pins lets the retry succeed.
$pinner->quit;

is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"),
	't',
	"shrink succeeds after pins released");

is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
	"$shrink_target|$shrink_target|$shrink_target|0",
	"pool shrunk to $shrink_target after pins released");

# ---------------------------------------------------------------------------
# Test the case when memory allocation fails when expanding the buffer pool.
# Uses an injection point to simulate the failure without exhausting real
# memory.
# ---------------------------------------------------------------------------

SKIP:
{
	skip "injection points not supported by this build"
	  unless $have_injection_points;

	# The buffer manager's resizable structures whose sizes must be rolled
	# back if any one of them fails to grow.
	my $resizable_structs =
	  q{('Buffer Descriptors', 'Buffer Blocks', 'Buffer IO Condition Variables', 'Checkpoint BufferIds')};
	my $sizes_query = "SELECT name, size FROM pg_shmem_allocations WHERE name IN $resizable_structs ORDER BY name";
	my $sizes_before = $node->safe_psql('postgres', $sizes_query);

	my $resizer = $node->background_psql('postgres');
	$resizer->query_safe("SELECT injection_points_set_local()", verbose => 0);
	$resizer->query_safe("SELECT injection_points_attach('buffer-mgr-resize-struct-fail', 'notice')",
		verbose => 0);

	my $expand_target = $max_nbuffers;
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$expand_target'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	my $expand_log_offset = -s $node->logfile;

	is($resizer->query("SELECT pg_resize_shared_buffers()"), 'f',
		"expansion fails when a structure can not be expanded");

	# Discard the expected WARNINGs so later query_safe calls do not die.
	$resizer->{stderr} = '';

	ok($node->log_contains(qr/failed to expand buffer pool structures/, $expand_log_offset),
		"log reports the expansion failure");

	is($node->safe_psql('postgres',
			"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$shrink_target|$shrink_target|$shrink_target|0",
		"buffer pool status after expansion failure");

	is($node->safe_psql('postgres',
			"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
		"$shrink_target (pending: $expand_target)",
		"pg_settings reports pending expand target");

	is($node->safe_psql('postgres', $sizes_query), $sizes_before,
		"resizable buffer manager structures rolled back to previous sizes");

	# Detach the injection point, to retry again. The retry should succeed.
	$resizer->query_safe(
		"SELECT injection_points_detach('buffer-mgr-resize-struct-fail')",
		verbose => 0);
	is($resizer->query("SELECT pg_resize_shared_buffers()"), 't',
		"expand succeeds after the injection point is detached");

	$resizer->quit;

	is($node->safe_psql('postgres', "SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$expand_target|$expand_target|$expand_target|0",
		"pool expanded to $expand_target after detach");
}

done_testing();
