# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress the pg_buffercache diagnostic and monitoring functions
# concurrently with shared_buffers resizing.
#
# Destructive functions like pg_buffercache_evict_* and
# pg_buffercache_mark_dirty_* are excluded because they might cause failures
# unrelated to the test.
#
# TODO: This test fails because pg_buffercache_os_pages_internal() expects the
# buffer pool size to be constant. Fix is on the way.

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

# A mix of small and large sizes exercises the resize logic in a variety
# of scenarios. At any time during the run buffer pool should be large
# enough to let a new backend join while other backends are scanning the
# buffer pool via pg_buffercache; avoid too small sizes.
my @buffer_sizes = (512, 1024, 4096, 16 * 1024, 32 * 1024, 128 * 1024);

my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_pg_buffercache_test',
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,);
$stress->setup;

$stress->node->safe_psql('postgres', 'CREATE EXTENSION pg_buffercache');

# Test specific workload. Include NUMA view only if the server supports NUMA.
my $workload_sql = qq{
SELECT count(*) FROM pg_buffercache;
SELECT * FROM pg_buffercache_summary();
SELECT count(*) FROM pg_buffercache_usage_counts();
SELECT count(*) FROM pg_buffercache_os_pages;
};
if ($stress->node->safe_psql('postgres', 'SELECT pg_numa_available()') eq 't')
{
    $workload_sql .= "SELECT count(*) FROM pg_buffercache_numa;\n";
}

# Use the default workload only to populate the buffer pool, but main workload
# is the pg_buffercache queries.
$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,);

done_testing();
