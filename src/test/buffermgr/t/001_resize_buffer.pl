# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Minimal test testing shared_buffer resizing under load

use strict;
use warnings;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Function to check if pgbench is still running.
#
# Relying on IPC::Run's pumpable status to check if pgbench is still running has
# been proven unreliable. Instead we rely on existence of pgbench processes in
# pg_stat_activity.  Since we use -C with pgbench, there can be a non-zero
# chance that no pgbench process is running even thought pgbench is running. But
# that's a very rare possibility that can be ignored.
sub pgbench_processes_active
{
	my ($node, $application_name) = @_;

	my $result = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE application_name = '$application_name';");
	return int($result) > 0;
}

my $resize_sql_func_def = q{
create or replace function pg_resize_shared_buffers_sql(new_size int, out num_tries int) returns int as $$
declare
    success boolean := false;
    tries int := 0;
    cur_setting text;
    pending_pattern text;
    target text := new_size::text;
begin
    -- Wait until pg_settings reports the new value as pending,
    -- i.e. "<old value> (pending: <new value>)".
    pending_pattern := '%(pending: ' || target || ')%';
    loop
        select setting into cur_setting
        from pg_settings where name = 'shared_buffers';
        exit when cur_setting like pending_pattern or cur_setting = target;
        perform pg_sleep(0.1);
        raise notice 'Current setting: %', cur_setting;
    end loop;

    -- pg_resize_shared_buffers() returns true on success; retry until it succeeds.
    while not success loop
        tries := tries + 1;
        select pg_resize_shared_buffers() into success;
        if not success then
            perform pg_sleep(0.1);
        end if;
        raise notice 'pg_resize_shared_buffers() attempt %: success = %', tries, success;
    end loop;

    -- Confirm the new value is in effect (no longer pending).
    select setting into cur_setting
    from pg_settings where name = 'shared_buffers';
    if cur_setting <> target then
        raise exception 'shared_buffers resize did not take effect: expected %, got %',
            target, cur_setting;
    end if;

    num_tries := tries;
    return;
end;
$$ language plpgsql;
};

# Function to resize buffer pool and verify the change.
sub apply_and_verify_buffer_change
{
	my ($node, $new_size) = @_;

	# Use the new pg_resize_shared_buffers() interface which handles everything synchronously
	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$new_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");
	$node->safe_psql('postgres', "SELECT pg_resize_shared_buffers_sql($new_size)");

	# Any failure in resizing the buffer pool will cause the test to timeout. So
	# if we reach here, the resize was successful. Just declare it as a
	# successful test so that we can see progress in the test output.
	ok(1, "Buffer pool resized to $new_size");
}

my @buffer_sizes = (128, 28, 16 * 1024, 32 * 1024, 1024, 512, 16, 24, 256, 128 * 1024, 16 * 1204);

# Initialize a cluster and start pgbench in the background for concurrent load.
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

# Permit resizing up to 1GB for this test and let the server start with 128MB.
$node->append_conf('postgresql.conf', qq{
max_shared_buffers = } . (sort { $b <=> $a } @buffer_sizes)[0] . qq{
shared_buffers = 16
log_statement = none
restart_after_crash = off
});

$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");
$node->safe_psql('postgres', $resize_sql_func_def);

my $pgb_scale = 10;
my $pgb_duration = 120;
my $pgb_num_clients = 10;
# make it easy to identify pgbench processes in pg_stat_activity
my $application_name = 'pgbench_buffer_resize_test';
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
my ($pgbench_stdin, $pgbench_stdout, $pgbench_stderr) = ('', '', '');
# Use --exit-on-abort so that the test stops on the first server crash or error,
# thus making it easy to debug the failure. Use -C to increase the chances of a
# new backend being created while resizing the buffer pool.
my $pgbench_process = IPC::Run::start(
	[
		'pgbench',
		'-p', $node->port,
		'-h', $node->host,
		'-T', $pgb_duration,
		'-c', $pgb_num_clients,
		'-C',
		'--exit-on-abort',
		'--continue-on-error',
		"dbname=postgres application_name=$application_name"
	],
	'<'  => \$pgbench_stdin,
	'>'  => \$pgbench_stdout,
	'2>' => \$pgbench_stderr
);

ok($pgbench_process, "pgbench started successfully");

# Resize buffer pool to various sizes while pgbench is running in the
# background. We use smaller sizes to induce frequent buffer eviction and
# allocation.  Also smaller buffer pool means frequent wraparound in background
# writer, default buffer allocation strategy and checkpointer.
#
# TODO: These are pseudo-randomly picked sizes, but we can do better.
my $tests_completed = 0;

# Reset background writer stats before starting the resize cycle
$node->safe_psql('postgres', "SELECT pg_stat_reset_shared('bgwriter')");

# Resize as many times as possible while pgbench is running.
while (pgbench_processes_active($node, $application_name))
{
	for my $target_size (@buffer_sizes)
	{
		# Stop if pgbench finished
		if (!pgbench_processes_active($node, $application_name))
		{
			last;
		}

		apply_and_verify_buffer_change($node, $target_size);
		$tests_completed++;

		# Wait for the resized buffer pool to stabilize.
		sleep(1);
	}
}

ok($tests_completed > scalar(@buffer_sizes), "All buffer size transitions were tested");
note "Completed $tests_completed buffer resize operations while pgbench was running";

# Check that the background writer did some work during the resize cycle
is($node->safe_psql('postgres', "SELECT buffers_clean > 0 FROM pg_stat_bgwriter"), 't', "Background writer ran during resize cycle");

# Make sure that pgbench finishes
$pgbench_process->signal('TERM');
ok((IPC::Run::finish $pgbench_process), "pgbench finished successfully");

# Log any error output from pgbench for debugging
diag("pgbench stderr:\n$pgbench_stderr");
diag("pgbench stdout:\n$pgbench_stdout");

# Ensure database is still functional after all the buffer changes
$node->connect_ok("dbname=postgres",
	"Database remains accessible after $tests_completed buffer resize operations");

done_testing();
