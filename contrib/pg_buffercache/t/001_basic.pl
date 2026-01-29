# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Test shared_buffer resizing coordination with client connections joining using injection points

use strict;
use warnings;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(sleep);

# Function to calculate expected buffer count from size string
sub calculate_buffer_count
{
	my ($size_string, $block_size) = @_;
	
	# Parse size and convert to bytes
	my ($size_val, $unit) = ($size_string =~ /(\d+)(\w+)/);
	my $size_bytes;
	if (lc($unit) eq 'kb') {
		$size_bytes = $size_val * 1024;
	} elsif (lc($unit) eq 'mb') {
		$size_bytes = $size_val * 1024 * 1024;
	} elsif (lc($unit) eq 'gb') {
		$size_bytes = $size_val * 1024 * 1024 * 1024;
	} else {
		# Default to kB if unit is not recognized
		$size_bytes = $size_val * 1024;
	}
	
	return int($size_bytes / $block_size);
}

# Initialize cluster with very small buffer sizes for testing
my $node = PostgreSQL::Test::Cluster->new('main');
my $shared_buffers_initial = '128MB';
$node->init;

# Configure for buffer resizing with very small buffer pool sizes for faster tests.
# TODO: for some reason parallel workers try to load default number of shared_buffers which doesn't work with lower max_shared_buffers. We need to fix that - somewhere it's picking default value of shared buffers. For now disable parallelism
$node->append_conf('postgresql.conf', 'shared_preload_libraries = injection_points');
$node->append_conf('postgresql.conf', qq{
max_shared_buffers = $shared_buffers_initial
shared_buffers = $shared_buffers_initial
max_parallel_workers_per_gather = 0
});

$node->start;

# Enable injection points
$node->safe_psql('postgres', "CREATE EXTENSION injection_points");

# Get the block size (this is fixed for the binary)
my $block_size = $node->safe_psql('postgres', "SHOW block_size");

# Try to create pg_buffercache extension for buffer analysis
eval { 
	$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");
};
if ($@) {
	$node->stop;
	plan skip_all => 'pg_buffercache extension not available - cannot verify buffer usage';
}

# Create dedicated sessions for injection point handling and test queries,
# so that we don't create new backends for test operations after starting
# resize operation. Only one backend, which tests new backend synchronization
# with resizing operation, should start after resizing has commenced.
my $injection_session = $node->background_psql('postgres');
my $query_session = $node->background_psql('postgres');
my $resize_session = $node->background_psql('postgres');
	
# Function to run a single injection point test
sub run_injection_point_test
{
	my ($test_name, $injection_point, $target_size, $operation_type) = @_;
	
	note("Test with $test_name ($operation_type)");
	
	# Update buffer pool size and wait for it to reflect pending state 
	$resize_session->query_safe("ALTER SYSTEM SET shared_buffers = '$target_size'");
	$resize_session->query_safe("SELECT pg_reload_conf()");
	my $pending_size_str = "pending: $target_size";
	$resize_session->poll_query_until("SELECT substring(current_setting('shared_buffers'), '$pending_size_str')", $pending_size_str);

	# Set up injection point in injection session
	$injection_session->query_safe("SELECT injection_points_attach('$injection_point', 'wait')");
	
	# Trigger resize
	$resize_session->query_until(
		qr/starting_resize/,
		q(
			\echo starting_resize
			SELECT pg_resize_shared_buffers();
		)
	);
	
	# Wait until resize actually reaches the injection point using the query session
	$query_session->wait_for_event('client backend', $injection_point);
	
	# Start bufferscan while resize is paused
	my $client = $node->background_psql('postgres');
	
	# Wake up the injection point from injection session
	$injection_session->query_safe("SELECT injection_points_wakeup('$injection_point')");
	
	# Wait for the resize operation to complete
	$resize_session->query(q(\echo 'done'));
	
	# Detach injection point from injection session
	$injection_session->query_safe("SELECT injection_points_detach('$injection_point')");
	
	# Verify resize completed successfully
	is($query_session->query_safe("SELECT current_setting('shared_buffers')"), $target_size,
		"resize completed successfully to $target_size");
	
	# Check buffer pool size using pg_buffercache after resize completion
	is($query_session->query_safe("SELECT COUNT(*) FROM pg_buffercache"), calculate_buffer_count($target_size, $block_size), "pg_buffercache COUNT(*) correct after $test_name ($operation_type)");
	
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

# Function to test buffercache scan behavior during resize operations
# This tests that pg_buffercache correctly handles concurrent resize operations
# by pausing the buffercache scan at various points while a resize occurs.
# The expected behavior is that pg_buffercache detects the resize and raises
# an appropriate error "number of shared buffers changed during scan".
sub run_buffercache_injection_test
{
	my ($test_name, $buffercache_injection_point, $target_size, $operation_type) = @_;
	
	note("Test buffercache with $test_name ($operation_type)");

	# Attach injection point at middle of buffercache scan
	$node->safe_psql('postgres', "SELECT injection_points_attach('$buffercache_injection_point', 'wait')");

	# Start buffercache query in background - it will pause at injection point
	my $buffercache_session = $node->background_psql('postgres');
	$buffercache_session->query_until(
		qr/starting_buffercache/,
		q(
			\echo starting_buffercache
			SELECT COUNT(*) FROM pg_buffercache;
		)
	);

	# Wait for buffercache to reach injection point
	$node->poll_query_until('postgres',
		"SELECT COUNT(*) > 0 FROM pg_stat_activity WHERE wait_event = '$buffercache_injection_point'",
		't');

	note("Buffercache scan is paused at injection point");

	# Change shared_buffers to target size and resize
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	# Wait for pending state
	$node->poll_query_until('postgres',
		"SELECT current_setting('shared_buffers') LIKE '%pending%'",
		't');

	note("Shared buffers change is pending, now resizing...");

	# Perform resize
	$node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()");

	note("Resize completed, now waking up buffercache scan...");

	# Wake up buffercache scan - THIS IS WHERE THE CRASH HAPPENS
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$buffercache_injection_point')");

	# Wait a moment for crash to occur
	sleep(1);

	# Check if server crashed by looking at logfile
	my $logfile = $node->logfile;
	my $log_contents = slurp_file($logfile);

	if ($log_contents =~ /terminating any other active server processes/)
	{
		fail("SERVER CRASHED - Bug confirmed: pg_buffercache crashes when buffer pool shrinks during scan ($test_name, $operation_type)");
		note("Log shows: terminating any other active server processes");
	}
	elsif ($log_contents =~ /number of shared buffers changed during scan of buffer cache/)
	{
		pass("pg_buffercache detected resize during $test_name ($operation_type)");
	}
	else
	{
		pass("No crash detected during $test_name ($operation_type)");
	}

	# Cleanup
	eval { $buffercache_session->quit; };
	eval { $node->safe_psql('postgres', "SELECT injection_points_detach('$buffercache_injection_point')"); };
}

# Function to test resize behavior while buffercache scan is in progress
# This tests that resize operations correctly handle concurrent buffercache scans.
# Similar to run_buffercache_injection_test, but starts the resize first and pauses
# it, then starts buffercache, pauses it, and wakes both in sequence.
# The buffercache scan should detect the resize and fail gracefully.
sub run_resize_during_buffercache_test
{
	my ($test_name, $resize_injection_point, $buffercache_injection_point, $target_size, $operation_type) = @_;
	
	note("Test resize during buffercache: $test_name ($operation_type)");

	# Attach injection points on both resize and buffercache
	$node->safe_psql('postgres', "SELECT injection_points_attach('$resize_injection_point', 'wait')");
	$node->safe_psql('postgres', "SELECT injection_points_attach('$buffercache_injection_point', 'wait')");

	# Change shared_buffers to target size
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	# Wait for pending state
	$node->poll_query_until('postgres',
		"SELECT current_setting('shared_buffers') LIKE '%pending%'",
		't');

	note("Shared buffers change is pending");

	# Start resize in background - it will pause at injection point
	my $resize_session = $node->background_psql('postgres');
	$resize_session->query_until(
		qr/starting_resize/,
		q(
			\echo starting_resize
			SELECT pg_resize_shared_buffers();
		)
	);

	# Wait for resize to reach injection point
	$node->poll_query_until('postgres',
		"SELECT COUNT(*) > 0 FROM pg_stat_activity WHERE wait_event = '$resize_injection_point'",
		't');

	note("Resize is paused at injection point");

	# Start buffercache query in background - it will pause at injection point
	my $buffercache_session = $node->background_psql('postgres');
	$buffercache_session->query_until(
		qr/starting_buffercache/,
		q(
			\echo starting_buffercache
			SELECT COUNT(*) FROM pg_buffercache;
		)
	);

	# Wait for buffercache to reach injection point
	$node->poll_query_until('postgres',
		"SELECT COUNT(*) > 0 FROM pg_stat_activity WHERE wait_event = '$buffercache_injection_point'",
		't');

	note("Buffercache scan is paused at injection point");

	# Now we have both operations paused - wake them up in sequence
	# First wake up resize
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$resize_injection_point')");

	# Give resize a moment to progress
	sleep(0.1);

	# Then wake up buffercache scan
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$buffercache_injection_point')");

	# Wait a moment for crash to occur
	sleep(1);

	# Check if server crashed by looking at logfile
	my $logfile = $node->logfile;
	my $log_contents = slurp_file($logfile);

	if ($log_contents =~ /terminating any other active server processes/)
	{
		fail("SERVER CRASHED - Bug confirmed: pg_buffercache crashes during resize $test_name ($operation_type)");
		note("Log shows: terminating any other active server processes");
	}
	elsif ($log_contents =~ /number of shared buffers changed during scan of buffer cache/)
	{
		pass("pg_buffercache detected resize during $test_name ($operation_type)");
	}
	else
	{
		pass("No crash detected during $test_name ($operation_type)");
	}

	# Cleanup
	eval { $resize_session->quit; };
	eval { $buffercache_session->quit; };
	eval { $node->safe_psql('postgres', "SELECT injection_points_detach('$resize_injection_point')"); };
	eval { $node->safe_psql('postgres', "SELECT injection_points_detach('$buffercache_injection_point')"); };
}

# Test buffercache injection points - pausing buffercache while resize occurs
my @buffercache_injection_tests = (
	{
		name => 'scan start',
		injection_point => 'pg-buffercache-scan-start',
	},
	{
		name => 'scan loop',
		injection_point => 'pg-buffercache-scan-loop',
	},
	{
		name => 'scan middle',
		injection_point => 'pg-buffercache-scan-middle',
	},
);

foreach my $test (@buffercache_injection_tests)
{
	# Test with shrinking
	run_buffercache_injection_test($test->{name}, $test->{injection_point}, '256kB', 'shrinking');
	
	# Test with expanding
	run_buffercache_injection_test($test->{name}, $test->{injection_point}, '384kB', 'expanding');
}

# Test combined scenarios - both resize and buffercache paused simultaneously
my @combined_injection_tests = (
	{
		name => 'flag set + scan start',
		resize_point => 'pg-resize-shared-buffers-flag-set',
		buffercache_point => 'pg-buffercache-scan-start',
	},
	{
		name => 'remap + scan middle',
		resize_point => 'pgrsb-after-shmem-resize',
		buffercache_point => 'pg-buffercache-scan-middle',
	},
);

foreach my $test (@combined_injection_tests)
{
	# Test with shrinking
	run_resize_during_buffercache_test(
		$test->{name},
		$test->{resize_point},
		$test->{buffercache_point},
		'240kB',
		'shrinking'
	);
	
	# Test with expanding  
	run_resize_during_buffercache_test(
		$test->{name},
		$test->{resize_point},
		$test->{buffercache_point},
		'368kB',
		'expanding'
	);
}

$injection_session->quit;
$query_session->quit;
$resize_session->quit;

done_testing();