# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress test the autoprewarm concurrently with shared_buffers resizing.

use strict;
use warnings;
use FindBin;
use lib $FindBin::RealBin;
use Test::More;
use StressUtil;

if (!$ENV{PG_TEST_EXTRA} || $ENV{PG_TEST_EXTRA} !~ /\bbufmgr_stress\b/)
{
	plan skip_all => "bufmgr_stress not enabled in PG_TEST_EXTRA";
}

my @buffer_sizes = (512, 1024, 4096, 16 * 1024, 32 * 1024, 128 * 1024);

my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_pg_prewarm_test',
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,);
$stress->setup;

my $node = $stress->node;

# Configure the autoprewarm background worker to run as frequently as possible.
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'pg_prewarm'
pg_prewarm.autoprewarm = on
pg_prewarm.autoprewarm_interval = 1s
});
$node->restart;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_prewarm');

# Dump the buffer pool through additional load to increase the likelihood of it
# happening concurrently with a resize. Wrap the call in an exception block to
# swallow "dump file is being used by PID N" errors.
my $workload_sql = qq{
DO \$\$
BEGIN
    PERFORM autoprewarm_dump_now();
EXCEPTION WHEN OTHERS THEN
    NULL;
END
\$\$;
};

$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,);

my $dumpfile = $node->data_dir . '/autoprewarm.blocks';
ok(-s $dumpfile, "buffer pool was dumped at least once");

# Restart to confirm that the dump file can be read and the buffer pool can be
# prewarmed.
my $log_offset = -s $node->logfile;
$node->restart;
$node->wait_for_log(
	qr/autoprewarm successfully prewarmed \d+ of \d+ previously-loaded blocks/,
	$log_offset);
pass("autoprewarm prewarmed shared buffers after restart");

done_testing();
