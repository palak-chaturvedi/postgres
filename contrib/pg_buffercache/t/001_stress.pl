# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Stress test: pg_buffercache scans during concurrent buffer pool resizing.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('stress');
$node->init;

# Sizes in 8kB blocks. restart_after_crash = off to fail hard on crashes.
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

# Long-lived backends (no -C) stress re-attach to resized shmem mid-query.
# Concurrent resizes serialize internally; losers return false, not asserted.
$node->pgbench(
	'--no-vacuum --client=10 --transactions=200 -b tpcb-like@5',
	0,
	[qr{actually processed}],
	[qr{^$}],
	'concurrent writes, scans, and resizes',
	{
		'buffercache_scan@10' => q{SELECT count(*) FROM pg_buffercache},
		# Range spans [shared_buffers, max_shared_buffers] so both bounds
		# are exercised.  pg_sleep() is a CheckForInterrupts point that
		# lets SIGHUP from pg_reload_conf() land in this backend before
		# pg_resize_shared_buffers() reads the new GUC value.
		'resize@2' => q{
			\set nbuf random(20, 160)
			ALTER SYSTEM SET shared_buffers = :nbuf;
			SELECT pg_reload_conf();
			SELECT pg_sleep(0.01);
			SELECT pg_resize_shared_buffers();
		},
	});

# Confirm at least one in-workload resize actually landed: the running
# shared_buffers must have moved away from the initial 16 blocks (128kB).
isnt($node->safe_psql('postgres', "SHOW shared_buffers"),
	'128kB',
	'at least one concurrent resize succeeded');

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

# pgbench --scale=1 populates pgbench_accounts with 100000 rows; the tpcb-like
# workload only updates rows, so the count must be preserved exactly.
my $rows = $node->safe_psql('postgres',
	"SELECT count(*) FROM pgbench_accounts");
is($rows, '100000', "pgbench_accounts row count preserved after stress");

$node->connect_ok("dbname=postgres",
	"database accessible after stress test");

$node->stop;
done_testing();
