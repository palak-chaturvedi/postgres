# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Exercise the buffer pool scan that drops buffers belonging to a given
# relation (DropRelationBuffers() and DropRelationsAllBuffers())
# concurrently with shared_buffers resizing.

use strict;
use warnings;
use FindBin;
use lib $FindBin::RealBin;
use List::Util qw(max);
use PostgreSQL::Test::Utils;
use Test::More;
use StressUtil;

# A mix of small and large sizes exercises the resize logic in a variety
# of scenarios.
my @buffer_sizes = (
	128, 28, 16 * 1024, 32 * 1024, 1024, 512, 16, 24, 256, 128 * 1024);

# The injection points verify that the buffer pool scan is exercised in
# DropRelationBuffers() and DropRelationsAllBuffers().  If those functions
# stop scanning the buffer pool the test is useless, so we assert that
# each fired at least once per workload transaction.
my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_drop_relation_buffers_test',
	injection_points =>
	  [ 'drop-relation-buffers-scan', 'drop-relations-all-buffers-scan' ],
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,
);
$stress->setup;

# Test specific load preparation.
#
# DropRelationBuffers() and DropRelationsAllBuffers() scan the buffer pool
# only when the size of the relation exceeds NBuffers/32.  Create a
# relation larger than max(@buffer_sizes)/32 so a scan always runs.  Dump
# it once so pgbench clients can COPY it back in each iteration instead of
# regenerating the data.
my $node = $stress->node;
my $tempdir = PostgreSQL::Test::Utils::tempdir;
my $refdata_path = "$tempdir/refdata.bin";
$node->safe_psql('postgres', qq{
    CREATE UNLOGGED TABLE refdata_source AS
        SELECT g AS a, repeat('x', 1900)::bytea AS b
        FROM generate_series(1, 16800) g;
});
$node->safe_psql('postgres',
	"COPY refdata_source TO '$refdata_path' WITH (FORMAT binary)");
my $max_nbuffers = max @buffer_sizes;
my $required_pages = int($max_nbuffers / 32) + 1;
my $refdata_pages = $node->safe_psql('postgres',
	"SELECT (pg_relation_size('refdata_source') / current_setting('block_size')::bigint)::int");
cmp_ok($refdata_pages, '>', $required_pages,
	"refdata_source spans more than NBuffers/32 pages at the largest tested pool size");

# Workload script fed to pgbench.
#
# Each client picks table names from a disjoint numeric range so table
# names from concurrent clients do not collide.
#
# CREATE + TRUNCATE run inside the same transaction so the TRUNCATE scans
# the buffer pool to drop any buffers that belong to the relation created
# earlier in the same transaction through DropRelationBuffers(). DROP
# TABLE exercises DropRelationsAllBuffers().
my $workload_sql = qq{
\\set tid :client_id * 100000000 + random(1, 100000000)
BEGIN;
CREATE TABLE t_:tid (a int, b bytea);
COPY t_:tid FROM '$refdata_path' WITH (FORMAT binary);
TRUNCATE t_:tid;
COPY t_:tid FROM '$refdata_path' WITH (FORMAT binary);
COMMIT;
DROP TABLE t_:tid;
};

$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,
);

done_testing();
