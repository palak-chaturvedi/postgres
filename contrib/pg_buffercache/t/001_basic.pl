# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Test pg_buffercache scan behavior during shared_buffer resizing using
# injection points.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Skip this test if injection points are not supported
if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

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

# Load injection_points and pg_buffercache extensions
$node->safe_psql('postgres', "CREATE EXTENSION injection_points");
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");

# Create dedicated sessions for injection point handling and test queries,
# so that we don't create new backends for test operations after starting
# resize operation.
my $injection_session = $node->background_psql('postgres');
my $query_session = $node->background_psql('postgres');
my $resize_session = $node->background_psql('postgres');

# Function to run a single injection point test.
sub run_injection_point_test
{
	my ($test_name, $injection_point, $target_size, $operation_type) = @_;

	# Silence the logging of the statements we run to avoid
	# unnecessarily bloating the test logs.  This runs before the
	# upgrade we're testing, so the details should not be very
	# interesting for debugging.  But if needed, you can make it more
	# verbose by setting this.
	my $verbose = 0;

	note("Test with $test_name ($operation_type)");

	# Update buffer pool size
	$resize_session->query_safe("ALTER SYSTEM SET shared_buffers = '$target_size'", verbose => $verbose);
	$resize_session->query_safe("SELECT pg_reload_conf()", verbose => $verbose);

	# Set up injection point in injection session
	$injection_session->query_safe("SELECT injection_points_attach('$injection_point', 'wait')", verbose => $verbose);

	# Create a new session for resize
	my $resize_session = $node->background_psql('postgres');
	$resize_session->query_until(
		qr/starting_resize/,
		q(
			\echo starting_resize
			SELECT pg_resize_shared_buffers();
		)
	);

	# Wait until resize actually reaches the injection point
	$query_session->wait_for_event('client backend', $injection_point, verbose => $verbose);

	# Start bufferscan while resize is paused
	my $client = $node->background_psql('postgres');
	$client->query_safe("SELECT count(*) FROM pg_buffercache", verbose => $verbose);

	# Wake up the injection point from injection session
	$injection_session->query_safe("SELECT injection_points_wakeup('$injection_point')", verbose => $verbose);

	# Wait for the resize operation to complete
	$resize_session->query(q(\echo 'done'), verbose => $verbose);
	$resize_session->quit;

	# Detach injection point from injection session
	$injection_session->query_safe("SELECT injection_points_detach('$injection_point')",verbose => $verbose);

	# Verify resize completed successfully
	is($query_session->query_safe("SELECT current_setting('shared_buffers')", verbose => $verbose), $target_size,
		"resize completed successfully to $target_size");

	# Confirm the server is functional and the resize took effect.
	my $result = $node->safe_psql('postgres',
		"SELECT setting from pg_settings where name = 'shared_buffers'");

	# Check buffer pool size using pg_buffercache after resize completion
	is($query_session->query_safe("SELECT COUNT(*) FROM pg_buffercache", verbose => $verbose),
		$result, "pg_buffercache COUNT(*) correct after $test_name ($operation_type)");

	# Wait for client to complete
	ok($client->quit, "client succeeded during $test_name ($operation_type)");
}

# Test injection points during buffer resize with client connections
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
	run_injection_point_test($test->{name}, $test->{injection_point}, '272kB', 'shrinking');

	# Test expanding scenario
	run_injection_point_test($test->{name}, $test->{injection_point}, '400kB', 'expanding');
}

my @shrink_only_tests = (
	{
		name => 'shrink barrier complete',
		injection_point => 'pgrsb-shrink-barrier-sent',
		size => '200kB',
	}
);
foreach my $test (@shrink_only_tests)
{
	run_injection_point_test($test->{name}, $test->{injection_point}, $test->{size}, 'shrinking only');
}

my @expand_only_tests = (
	{
		name => 'expand barrier complete',
		injection_point => 'pgrsb-expand-barrier-sent',
		size => '416kB',
	}
);
foreach my $test (@expand_only_tests)
{
	run_injection_point_test($test->{name}, $test->{injection_point}, $test->{size}, 'expanding only');
}

# Function to test buffercache scan behavior during resize operations.
sub run_buffercache_injection_test
{
	my ($test_name, $buffercache_injection_point, $target_size, $operation_type) = @_;

	my $verbose = 0;

	note("Test buffercache with $test_name ($operation_type)");

	# Attach injection point at the buffercache scan
	$injection_session->query_safe(
		"SELECT injection_points_attach('$buffercache_injection_point', 'wait')",
		verbose => $verbose);

	# Start buffercache query in background - it will pause at injection point.
	# Use on_error_stop => 0 so psql stays alive if the query errors out.
	my $buffercache_session = $node->background_psql('postgres', on_error_stop => 0);
	$buffercache_session->query_until(
		qr/starting_buffercache/,
		q(
			\echo starting_buffercache
			SELECT COUNT(*) FROM pg_buffercache;
		)
	);

	# Wait for buffercache to reach injection point
	$query_session->wait_for_event('client backend', $buffercache_injection_point,
		verbose => $verbose);

	# Change shared_buffers to target size and reload config
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	# Start a new background session for resize
	$resize_session->query_safe("SELECT pg_resize_shared_buffers()",
		verbose => $verbose);
	$resize_session->quit;

	# Wake up buffercache scan and collect its results
	$injection_session->query_safe(
		"SELECT injection_points_wakeup('$buffercache_injection_point')",
		verbose => $verbose);

	my ($buffercache_output, $buffercache_err);
	eval { ($buffercache_output, $buffercache_err) = $buffercache_session->query(q(\echo 'done')); };
	my $query_err = $@;

	# Print the stderr/stdout output (even if query() died due to crash)
	note("buffercache stderr during $test_name ($operation_type): \n" . ($buffercache_session->{stderr} // ''));
	note("buffercache stdout during $test_name ($operation_type): \n" . ($buffercache_output // ''));
	note("buffercache query error during $test_name ($operation_type): $query_err") if $query_err;
	$buffercache_session->{stderr} = '';

	eval { $buffercache_session->quit; };

	# Detach injection point
	eval {
		$injection_session->query_safe(
			"SELECT injection_points_detach('$buffercache_injection_point')",
			verbose => $verbose);
	};

	# Confirm the server is functional and the resize took effect.
	my $result = $node->safe_psql('postgres', "SELECT setting from pg_settings where name = 'shared_buffers'");

	is($query_session->query_safe("SELECT COUNT(*) FROM pg_buffercache",
			verbose => $verbose),
		$result,
		"pg_buffercache count matches after $test_name ($operation_type)");
}

# Test buffercache injection points - pausing buffercache while resize occurs
my @buffercache_injection_tests = (
	{
		name => 'before the buffer pool scan starts',
		injection_point => 'pg-buffercache-scan-start',
	}, # Basic fail where after buffer change there are valid buffers
	# {
	# 	name => 'before getting buffer description - 2',
	# 	injection_point => 'pg-buffercache-after-getdesc',
	# }, # Failure where after buffer change there are no valid buffers;
);

foreach my $test (@buffercache_injection_tests)
{
	# Test with shrinking
	run_buffercache_injection_test($test->{name}, $test->{injection_point}, '256kB', 'shrinking');

	# Test with expanding
	run_buffercache_injection_test($test->{name}, $test->{injection_point}, '384kB', 'expanding');
}

$injection_session->quit;
$query_session->quit;

done_testing();