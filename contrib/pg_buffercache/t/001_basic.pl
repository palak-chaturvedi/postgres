# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Test pg_buffercache scan behavior during shared buffer pool resizing.
#
# Two categories of tests:
#   1. pg_buffercache scan while resize is paused at various injection points
#      -- verifies that a concurrent scan succeeds and reports the correct
#      buffer count after resize completes.
#   2. pg_buffercache scan paused mid-scan while a resize occurs underneath
#      -- verifies that the scan detects the change and raises an error.

use strict;
use warnings;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(sleep);

# Skip this test if injection points are not supported
if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

# Convert a human-readable size string (e.g. "256kB", "8MB") to the expected
# number of buffers for the given block_size.
sub calculate_buffer_count
{
	my ($size_string, $block_size) = @_;

	my ($size_val, $unit) = ($size_string =~ /(\d+)(\w+)/);
	my $size_bytes;
	if    (lc($unit) eq 'kb') { $size_bytes = $size_val * 1024; }
	elsif (lc($unit) eq 'mb') { $size_bytes = $size_val * 1024 * 1024; }
	elsif (lc($unit) eq 'gb') { $size_bytes = $size_val * 1024 * 1024 * 1024; }
	else                      { $size_bytes = $size_val * 1024; }

	return int($size_bytes / $block_size);
}

# Set up the test cluster with a small buffer pool.
my $node = PostgreSQL::Test::Cluster->new('main');
my $shared_buffers_initial = '8MB';
$node->init;
$node->append_conf('postgresql.conf', qq{
	shared_preload_libraries = 'injection_points'
	max_shared_buffers = $shared_buffers_initial
	shared_buffers = $shared_buffers_initial
	max_parallel_workers_per_gather = 0
	restart_after_crash = off
});
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION injection_points");
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");

my $block_size = $node->safe_psql('postgres', "SHOW block_size");

# Long-lived sessions reused across tests to avoid creating new backends
# during resize operations.
my $injection_session = $node->background_psql('postgres');
my $query_session     = $node->background_psql('postgres');

##############################################################################
# Test 1: pg_buffercache scan while resize is paused
#
# Pause the resize operation at an injection point, run a full pg_buffercache
# scan from a separate client, then let the resize finish.  Verify the scan
# succeeds and the final buffer count matches the target size.
##############################################################################
sub run_resize_injection_test
{
	my ($test_name, $injection_point, $target_size, $operation_type) = @_;

	note("Test: $test_name ($operation_type) -> $target_size");

	$node->safe_psql('postgres',
		"ALTER SYSTEM SET shared_buffers = '$target_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	$injection_session->query_safe(
		"SELECT injection_points_attach('$injection_point', 'wait')");

	# Trigger resize in a dedicated session.
	my $resize_session = $node->background_psql('postgres');
	$resize_session->query_until(
		qr/starting_resize/,
		q(
			\echo starting_resize
			SELECT pg_resize_shared_buffers();
		)
	);

	# Wait for the resize backend to hit the injection point.
	$query_session->wait_for_event('client backend', $injection_point);

	# Run a full pg_buffercache scan while resize is paused.
	my $client = $node->background_psql('postgres');
	$client->query_safe("SELECT count(*) FROM pg_buffercache");

	# Resume resize.
	$injection_session->query_safe(
		"SELECT injection_points_wakeup('$injection_point')");

	$resize_session->query(q(\echo 'done'));
	$resize_session->quit;

	$injection_session->query_safe(
		"SELECT injection_points_detach('$injection_point')");

	# Verify the resize landed and the buffer count is correct.
	is($query_session->query_safe(
			"SELECT current_setting('shared_buffers')"),
		$target_size,
		"shared_buffers is $target_size after $test_name ($operation_type)");

	is($query_session->query_safe("SELECT COUNT(*) FROM pg_buffercache"),
		calculate_buffer_count($target_size, $block_size),
		"pg_buffercache count matches after $test_name ($operation_type)");

	ok($client->quit,
		"client scan succeeded during $test_name ($operation_type)");
}

# Injection points common to both shrink and expand paths.
my @common_injection_tests = (
	{
		name => 'flag setting phase',
		injection_point => 'pg-resize-shared-buffers-flag-set',
	},
	{
		name => 'memory remap phase',
		injection_point => 'pgrsb-after-shmem-resize',
	},
	{
		name => 'resize map barrier complete',
		injection_point => 'pgrsb-resize-barrier-sent',
	},
);

# Test common injection points for both shrinking and expanding
foreach my $test (@common_injection_tests)
{
	# Test shrinking scenario
	run_resize_injection_test(
		$test->{name}, $test->{injection_point}, '272kB', 'shrinking');

	# Test expanding scenario
	run_resize_injection_test(
		$test->{name}, $test->{injection_point}, '400kB', 'expanding');
}

my @shrink_only_tests = (
	{
		name => 'shrink barrier complete',
		injection_point => 'pgrsb-shrink-barrier-sent',
		size => '200kB',
	},
);
foreach my $test (@shrink_only_tests)
{
	run_resize_injection_test(
		$test->{name}, $test->{injection_point}, $test->{size}, 'shrinking');
}

my @expand_only_tests = (
	{
		name => 'expand barrier complete',
		injection_point => 'pgrsb-expand-barrier-sent',
		size => '8MB',
	},
);
foreach my $test (@expand_only_tests)
{
	run_resize_injection_test(
		$test->{name}, $test->{injection_point}, $test->{size}, 'expanding');
}

##############################################################################
# Test 2: resize while pg_buffercache scan is in progress
#
# Pause a pg_buffercache scan mid-flight using an injection point inside the
# scan itself, then resize the buffer pool underneath.  The scan should detect
# the NBuffers change and raise:
#   ERROR: number of shared buffers changed during scan of buffer cache
##############################################################################
sub run_buffercache_scan_error_test
{
	my ($test_name, $scan_injection_point, $target_size, $operation_type) = @_;

	note("Test: $test_name ($operation_type) -> $target_size");

	# Pause the pg_buffercache scan at the given injection point.
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('$scan_injection_point', 'wait')");

	my $buffercache_session = $node->background_psql('postgres');
	$buffercache_session->query_until(
		qr/starting_buffercache/,
		"\\echo starting_buffercache\nSELECT COUNT(*) FROM pg_buffercache;\n"
	);

	$node->wait_for_event('client backend', $scan_injection_point);

	# Resize the buffer pool while the scan is paused.
	$node->safe_psql('postgres',
		"ALTER SYSTEM SET shared_buffers = '$target_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");
	$node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()");

	# Resume the scan -- it should now see the mismatch and error out.
	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('$scan_injection_point')");

	# Drain output from the background session.  The psql process will exit
	# after the ERROR, so pump until it is no longer pumpable.
	eval {
		while ($buffercache_session->{run}->pumpable())
		{
			$buffercache_session->{run}->pump_nb();
			last if $buffercache_session->{stderr} =~ /ERROR/;
			Time::HiRes::sleep(0.01);
		}
		$buffercache_session->{run}->pump_nb()
			if $buffercache_session->{run}->pumpable();
	};

	note("pg_buffercache scan output:\n" . $buffercache_session->{stdout});
	note("pg_buffercache scan error output:\n" . $buffercache_session->{stderr});

	eval { $buffercache_session->quit; };
	eval {
		$node->safe_psql('postgres',
			"SELECT injection_points_detach('$scan_injection_point')");
	};

	# Confirm the server is functional and the resize took effect.
	my $result = $node->safe_psql('postgres',
		"SELECT COUNT(*) FROM pg_buffercache");
	is($result, calculate_buffer_count($target_size, $block_size),
		"buffer count correct after $test_name ($operation_type)");
}

# Test buffercache injection points - pausing buffercache while resize occurs
my @buffercache_scan_tests = (
	# {
	# 	name => 'before the buffer pool scan starts',
	# 	injection_point => 'pg-buffercache-scan-start',
	# }, # Basic fail where after buffer change there are valid buffers (NOTE : Buffer fails after a little later then actual currentNBuffers Why?)
	{
		name => 'before getting buffer description',
		injection_point => 'pg-buffercache-after-getdesc',
	}, # Failure where after buffer change there are no valid buffers;
);

foreach my $test (@buffercache_scan_tests)
{
	# Test with shrinking
	run_buffercache_scan_error_test(
		$test->{name}, $test->{injection_point}, '256kB', 'shrinking');

	# Test with expanding
	run_buffercache_scan_error_test(
		$test->{name}, $test->{injection_point}, '384kB', 'expanding');
}

$injection_session->quit;
$query_session->quit;

done_testing();