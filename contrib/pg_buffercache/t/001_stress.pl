# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress test for pg_buffercache scans during concurrent shared buffer
# pool resizing.
#
# Runs three concurrent pgbench workloads:
#   - tpcb-like (weight 5): write-heavy TPC-B generating dirty buffers / WAL
#   - buffercache_scan (weight 10): SELECT count(*) FROM pg_buffercache
#   - resize (weight 2): randomly resize the buffer pool between 16 and 150
#     buffers (128 kB – 1200 kB) via pg_resize_shared_buffers()
#
# After the concurrent phase, the pool is resized to a known size and
# post-stress sanity checks verify the buffer count, data readability,
# and connectivity.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('stress');
$node->init;

# max_shared_buffers = 160 (upper bound for dynamic resizing, in 8kB blocks).
# shared_buffers = 16 (start small so the first resizes grow the pool).
# restart_after_crash = off so a crash causes the test to fail rather than
# silently recovering.
$node->append_conf('postgresql.conf', qq{
max_shared_buffers = 160
shared_buffers = 16
restart_after_crash = off
log_statement = none
});

$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION pg_buffercache");

$node->pgbench(
	"--initialize --init-steps=dtpvg --scale=1 --quiet",
	0,
	[qr{^$}],
	[qr{dropping old tables}, qr{creating tables},
	 qr{done in \d+\.\d\d s }],
	"pgbench init");

# 10 clients x 500 transactions, -C reconnects each transaction.
# Script weights: tpcb-like@5, buffercache_scan@10, resize@2.
$node->pgbench(
	'--no-vacuum --client=10 --transactions=500 -C '
	  . '-b tpcb-like@5',
	0,
	[qr{actually processed}],
	[qr{^$}],
	'concurrent writes, scans, and resizes',
	{
		'buffercache_scan@10' => q{
			SELECT count(*) FROM pg_buffercache;
		},
		# :nbuf is in 8kB blocks (the default unit for shared_buffers).
		# The short sleep lets the config reload propagate before we
		# attempt the actual resize.
		'resize@2' => q{
			\set nbuf random(16, 150)
			ALTER SYSTEM SET shared_buffers = :nbuf;
			SELECT pg_reload_conf();
			SELECT pg_sleep(0.01);
			SELECT pg_resize_shared_buffers();
		},
	});

# Resize to a known final size and verify.
my $final_buffers = 24;
my $final_size = ($final_buffers * 8) . 'kB';
$node->safe_psql('postgres',
	"ALTER SYSTEM SET shared_buffers = '$final_size'");
$node->safe_psql('postgres', "SELECT pg_reload_conf()");
my $resized = $node->safe_psql('postgres',
	"SELECT pg_resize_shared_buffers()");
is($resized, 't', "final resize to $final_size succeeded");

is($node->safe_psql('postgres', "SHOW shared_buffers"),
	$final_size,
	"SHOW confirms final resize to $final_size");

is($node->safe_psql('postgres', "SELECT count(*) FROM pg_buffercache"),
	$final_buffers,
	"pg_buffercache count matches final size ($final_buffers buffers)");

my $rows = $node->safe_psql('postgres',
	"SELECT count(*) FROM pgbench_accounts");
cmp_ok($rows, '>', 0, "pgbench_accounts still readable after stress");

$node->connect_ok("dbname=postgres",
	"database accessible after stress test");

$node->stop;
done_testing();