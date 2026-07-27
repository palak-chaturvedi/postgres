# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress test execution of DropRelationBuffers(), DropRelationsAllBuffers() and
# FlushRelationsAllBuffers() concurrently with shared_buffers resizing.

use strict;
use warnings;
use FindBin;
use lib $FindBin::RealBin;
use List::Util qw(max);
use PostgreSQL::Test::Utils;
use Test::More;
use StressUtil;

if (!$ENV{PG_TEST_EXTRA} || $ENV{PG_TEST_EXTRA} !~ /\bbufmgr_stress\b/)
{
	plan skip_all => "bufmgr_stress not enabled in PG_TEST_EXTRA";
}

# A mix of small and large sizes exercises the resize logic in a variety
# of scenarios. At any time during the run buffer pool should be large enough to
# let a new backend join while other backends are performing COPY, which seems
# to pin many buffers at a time; avoid too small sizes.
my @buffer_sizes = (512, 1024, 4096, 16 * 1024, 32 * 1024, 128 * 1024);

# The injection points verify that the buffer pool scan is exercised as expected
my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_drop_relation_buffers_test',
	injection_points => [
		'drop-relation-buffers-scan',
		'drop-relations-all-buffers-scan',
		'flush-relations-all-buffers-scan',
	],
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,);
$stress->setup;

# Force execution of FlushRelationsAllBuffers() by skipping WAL logging DMLs to
# a newly created table.
my $node = $stress->node;
$node->append_conf(
	'postgresql.conf', qq{
wal_level = minimal
max_wal_senders = 0
wal_skip_threshold = 0
});
$node->restart;

# Test specific load preparation.
#
# DropRelationBuffers() and DropRelationsAllBuffers() scan the buffer pool
# only when the size of the relation exceeds NBuffers/32.  Create a
# relation larger than max(@buffer_sizes)/32 so a scan always runs.  Dump
# it once so pgbench clients can COPY it back in each iteration instead of
# regenerating the data.
my $tempdir = PostgreSQL::Test::Utils::tempdir;
my $refdata_path = "$tempdir/refdata.bin";
$node->safe_psql(
	'postgres', qq{
    CREATE UNLOGGED TABLE refdata_source AS
        SELECT g AS a, repeat('x', 1900)::bytea AS b
        FROM generate_series(1, 16800) g;
});
$node->safe_psql('postgres',
	"COPY refdata_source TO '$refdata_path' WITH (FORMAT binary)");
my $max_nbuffers = max @buffer_sizes;
my $required_pages = int($max_nbuffers / 32) + 1;
my $refdata_pages = $node->safe_psql('postgres',
	"SELECT (pg_relation_size('refdata_source') / current_setting('block_size')::bigint)::int"
);
cmp_ok($refdata_pages, '>', $required_pages,
	"refdata_source spans more than NBuffers/32 pages at the largest tested pool size"
);

# Workload script fed to pgbench.
#
# Each client picks table names from a disjoint numeric range so table
# names from concurrent clients do not collide.  The :pgbench_id prefix
# further disambiguates across the two pgbench flavors (persistent /
# per_transaction) that StressUtil runs in parallel.
my $workload_sql = qq{
\\set tid :pgbench_id * 1000000000 + :client_id * 100000000 + random(1, 100000000)
BEGIN;
CREATE TABLE t_:tid (a int, b bytea);
COPY t_:tid FROM '$refdata_path' WITH (FORMAT binary);
TRUNCATE t_:tid;	-- hit DropRelationBuffers()
COPY t_:tid FROM '$refdata_path' WITH (FORMAT binary);
COMMIT;	-- hit FlushRelationsAllBuffers()
DROP TABLE t_:tid;	-- hit DropRelationsAllBuffers()
};

$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,);

done_testing();
