# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Stress test for shared_buffer resizing under concurrent read and write load.
# Runs pgbench TPC-B (writes) and pg_buffercache scans (reads) while resizing
# the buffer pool through a range of sizes including near the maximum.

use strict;
use warnings;
use File::Basename;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Function to resize buffer pool and verify the change.
sub apply_and_verify_buffer_change
{
	my ($node, $new_size) = @_;
	
	# Use the new pg_resize_shared_buffers() interface which handles everything synchronously
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$new_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");
	
	# If resize function fails, try a few times before giving up
	my $max_retries = 5;
	my $retry_delay = 1; # seconds
	my $success = 0;
	for my $attempt (1..$max_retries) {
		my $result = $node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()");
		if ($result eq 't') {
			$success = 1;
			last;
		}
		
		# If not the last attempt, wait before retrying
		if ($attempt < $max_retries) {
			note "Resizing buffer pool to $new_size, attempt $attempt failed, retrying after $retry_delay seconds...";
			sleep($retry_delay);
		}
	}
	
	is($success, 1, 'resizing to ' . $new_size . ' succeeded after retries');
	is($node->safe_psql('postgres', "SHOW shared_buffers"), $new_size,
		'SHOW after resizing to '. $new_size . ' succeeded');
}

# Initialize a cluster and start pgbench in the background for concurrent load.
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

# Permit resizing up to 160 buffers (1280kB) and start with 16 buffers (128kB).
$node->append_conf('postgresql.conf', qq{
max_shared_buffers = 160
shared_buffers = 16
log_statement = none
});

$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");
my $pgb_scale = 1;
my $pgb_duration = 40;
my $pgb_num_clients = 3;
$node->pgbench(
	"--initialize --init-steps=dtpvg --scale=$pgb_scale --quiet",
	0,
	[qr{^$}],
	[   # stderr patterns to verify initialization stages
		qr{dropping old tables},
		qr{creating tables},
		qr{done in \d+\.\d\d s }
	],
	"pgbench initialization (scale=$pgb_scale)"
);

# Start pgbench with default TPC-B workload for write-heavy load (dirty buffers,
# WAL, checkpointing).  Use -C to create new connections during resize and
# --exit-on-abort to stop on server crash.
my ($write_stdin, $write_stdout, $write_stderr) = ('', '', '');
my $write_process = IPC::Run::start(
	[
		'pgbench',
		'-p', $node->port,
		'-T', $pgb_duration,
		'-c', $pgb_num_clients,
		'-C',
		'--exit-on-abort',
		'postgres'
	],
	'<'  => \$write_stdin,
	'>'  => \$write_stdout,
	'2>' => \$write_stderr
);
ok($write_process, "pgbench TPC-B (write) started successfully");

# Start a second pgbench with pg_buffercache scans for read-only load that
# exercises the buffer descriptor array during resize.
my ($scan_stdin, $scan_stdout, $scan_stderr) = ('', '', '');
my $script_file = dirname(__FILE__) . '/../sql/buffercache_scan.sql';
my $scan_process = IPC::Run::start(
	[
		'pgbench',
		'-p', $node->port,
		'-T', $pgb_duration,
		'-c', $pgb_num_clients,
		'-C',
		'--exit-on-abort',
		'-f', $script_file,
		'postgres'
	],
	'<'  => \$scan_stdin,
	'>'  => \$scan_stdout,
	'2>' => \$scan_stderr
);
ok($scan_process, "pgbench buffercache scan (read) started successfully");

# Allow pgbench to establish connections and start generating load.
sleep(1);

# Resize buffer pool to various sizes while both pgbench workloads are running.
# Small sizes induce frequent buffer eviction and allocation; sizes near
# max_shared_buffers stress the upper boundary.
my $tests_completed = 0;
my @buffer_sizes = (32, 24, 29, 40, 29, 20, 16, 150, 80, 24);
for my $target_size (@buffer_sizes)
{
	# Convert number of buffers to a string that will be reported by SHOW
	# shared_buffers. This simple calculation works for sizes smaller than 128
	# beyond which the unit changes to MB.
	$target_size = $target_size * 8;
	$target_size = $target_size . 'kB';

	# Verify both workload generators are still running
	if (!$write_process->pumpable) {
		ok(0, "pgbench TPC-B is still running during resize to $target_size");
		last;
	}
	if (!$scan_process->pumpable) {
		ok(0, "pgbench scan is still running during resize to $target_size");
		last;
	}
	
	apply_and_verify_buffer_change($node, $target_size);
	$tests_completed++;
	
	# Wait for the resized buffer pool to stabilize. If the resized buffer pool
	# is utilized fully, it might hit any wrongly initialized areas of shared
	# memory.
	sleep(2);
}
is($tests_completed, scalar(@buffer_sizes), "All buffer sizes were tested");

# Verify pg_buffercache count matches the final resize target.
# Last target: 24 buffers (192kB).
my $expected_buffers = 24;
is($node->safe_psql('postgres', "SELECT count(*) FROM pg_buffercache"),
	$expected_buffers,
	"pg_buffercache count matches final buffer pool size ($expected_buffers)");

# Shut down both pgbench processes.
for my $proc ($write_process, $scan_process) {
	if ($proc->pumpable) {
		$proc->signal('TERM');
	}
	IPC::Run::finish $proc;
}
ok(grep({ $write_process->result == $_ } (0, 15)),
	"pgbench TPC-B exited gracefully");
ok(grep({ $scan_process->result == $_ } (0, 15)),
	"pgbench scan exited gracefully");

# Log any error output from pgbench for debugging.
diag("pgbench TPC-B stderr:\n$write_stderr");
diag("pgbench scan stderr:\n$scan_stderr");

# Ensure database is still functional after all the buffer changes
$node->connect_ok("dbname=postgres", 
	"Database remains accessible after $tests_completed buffer resize operations");

done_testing();