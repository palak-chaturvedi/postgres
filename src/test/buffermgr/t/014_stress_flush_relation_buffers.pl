# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress FlushRelationBuffers() concurrently with shared_buffers
# resizing.

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
# of scenarios. At any time during the run the buffer pool must be large
# enough to let a new backend join while other backends are CLUSTERing a
# small table, which pins several buffers at once; avoid too small sizes.
my @buffer_sizes = (512, 1024, 4096, 16 * 1024, 32 * 1024, 128 * 1024);

# The injection point verifies that the buffer pool scan is exercised in
# FlushRelationBuffers().  If the function stops scanning the buffer pool
# the test is useless, so we assert that it fires at least once per
# workload transaction.
my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_flush_relation_buffers_test',
	injection_points => ['flush-relation-buffers-scan'],
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,);

$stress->setup;

my $node = $stress->node;
my $ts2_dir = $node->basedir . '/tblsp2';
mkdir $ts2_dir or die "mkdir $ts2_dir: $!";
$node->safe_psql('postgres', "CREATE TABLESPACE ts2 LOCATION '$ts2_dir'");

# Workload script fed to pgbench.
#
# Each client picks table names from a disjoint numeric range so table
# names from concurrent clients do not collide.  The :pgbench_id prefix
# further disambiguates across the two pgbench flavors (persistent /
# per_transaction) that StressUtil runs in parallel.
my $workload_sql = qq{
\\set tid :pgbench_id * 1000000000 + :client_id * 100000000 + random(1, 100000000)
BEGIN;
CREATE TABLE t_:tid (a int PRIMARY KEY, b bytea);
INSERT INTO t_:tid
	SELECT g, repeat('x', 1900)::bytea
	  FROM generate_series(1, 100) g;
-- hit FlushRelationBuffers()
ALTER TABLE t_:tid SET TABLESPACE ts2;
ALTER TABLE t_:tid SET TABLESPACE pg_default;
DROP TABLE t_:tid;
COMMIT;
};

$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,);

done_testing();
