# Copyright (c) 2026-2026, PostgreSQL Global Development Group
#
# Test that pg_resize_shared_buffers() errors out when resizable shared
# memory is not supported.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $initial_nbuffers = 256;
my $max_nbuffers = 512;
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf', qq{
shared_buffers = $initial_nbuffers
max_shared_buffers = $max_nbuffers
});
$node->start;

if ($node->safe_psql('postgres', 'SHOW have_resizable_shmem') eq 'on')
{
    # The builds that support resizable shared memory, usually, will not support
    # the feature when SysV shared memory is used.
	$node->safe_psql('postgres',
		"ALTER SYSTEM SET shared_memory_type = 'sysv'");
	$node->restart;
}

is( $node->safe_psql('postgres', 'SHOW have_resizable_shmem'),
	'off',
	'have_resizable_shmem reports off');

my $target_nbuffers = $initial_nbuffers / 2;
$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target_nbuffers'");
$node->safe_psql('postgres', "SELECT pg_reload_conf()");

my ($ret, $stdout, $stderr) =
  $node->psql('postgres', "SELECT pg_resize_shared_buffers()");
isnt($ret, 0,
	'pg_resize_shared_buffers fails when resizable shared memory is unsupported'
);
like(
	$stderr,
	qr/resizing shared buffer pool is not supported on this platform/,
	'error message reports that resizing shared buffer pool is unsupported'
);

done_testing();
