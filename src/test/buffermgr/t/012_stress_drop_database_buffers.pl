# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Exercise the buffer pool scan that drops buffers belonging to a given
# database (DropDatabaseBuffers()) concurrently with shared_buffers
# resizing.

use strict;
use warnings;
use FindBin;
use lib $FindBin::RealBin;
use List::Util qw(max);
use Test::More;
use StressUtil;

# A mix of small and large sizes exercises the resize logic in a variety of
# scenarios. Avoid very small sizes because concurrent CREATE DATABASE clones
# can pin more buffers than a very small pool provides, which can cause
# unrelated failures.
my @buffer_sizes =
  (128, 256, 512, 1024, 4096, 16 * 1024, 32 * 1024, 128 * 1024);

my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	initial_shared_buffers => 1024,
	application_name => 'pgbench_drop_database_buffers_test',
	injection_points => ['drop-database-buffers-scan'],

	# Concurrent CREATE DATABASE clones pin many buffers per client; raising
	# this can exhaust the small pool sizes resulting in the
	# pg_resize_shared_buffers() query failing with and fail with error "no
	# unpinned buffers available".
	pgbench_clients => 4,
	pgbench_scale => 10,
	pgbench_duration => 120,
);

$stress->setup;

# Populate a template database with enough data. Size the seed table to roughly
# 1/8 of the largest buffer pool we exercise.  At the largest pool it still
# occupies ~12% so that DropDatabaseBuffers() finds enough fraction of buffers
# to drop. At smaller pool sizes the template exceeds the pool, thus covering
# all the combinations of scanning buffer pool and dropping buffers.
# 
# The 1900-byte payload makes sure that each row remains in the heap.
my $node = $stress->node;
my $seed_template = 'seedtemplate';
my $max_buffer_pool = max @buffer_sizes;
my $seed_row_count = 4 * $max_buffer_pool / 8;
$node->safe_psql('postgres', "CREATE DATABASE $seed_template");
$node->safe_psql(
	$seed_template, qq{
    CREATE TABLE seedtab (a int, b bytea);
    INSERT INTO seedtab
        SELECT g, repeat('x', 1900)::bytea
        FROM generate_series(1, $seed_row_count) g;
});
$node->safe_psql('postgres',
	    "UPDATE pg_database SET datistemplate = true, datallowconn = false "
	  . "WHERE datname = '$seed_template'");

# Workload script fed to pgbench.
#
# Each client picks database names from a disjoint numeric range so
# database names from concurrent clients do not collide.
my $workload_sql = qq{
\\set tid :client_id * 100000000 + random(1, 100000000)
CREATE DATABASE d_:tid TEMPLATE $seed_template;
DROP DATABASE d_:tid;
};

$stress->run(
	workload_sql => $workload_sql,
	workload_weight => 10,
	default_load_weight => 1,
);

done_testing();
