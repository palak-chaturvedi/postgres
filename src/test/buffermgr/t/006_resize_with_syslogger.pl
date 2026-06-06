# Copyright (c) 2026-2026, PostgreSQL Global Development Group
#
# Test that pg_resize_shared_buffers() works when a backend that never
# attaches to shared memory is running.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $initial_nbuffers = 16;
my $expanded_nbuffers = 24;
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

# When logging_collector is on, the server starts a syslogger process that never
# attaches to the shared memory. We use that as a proxy for a backend that never
# attaches to shared memory.
$node->append_conf(
	'postgresql.conf', qq{
shared_buffers = $initial_nbuffers
max_shared_buffers = $expanded_nbuffers
logging_collector = on
});
$node->start;

# Check that the syslogger is running by writing a log marker and waiting for it
# to appear in the log file.
sub check_syslogger_running
{
	my ($marker) = @_;

	$node->safe_psql('postgres', "DO \$\$ BEGIN RAISE LOG '$marker'; END \$\$");
	return $node->poll_query_until('postgres', "SELECT pg_read_file(pg_current_logfile()) ~ '$marker'");
}

check_syslogger_running('syslogger_marker_before_resize')
  or die "syslogger is not running";

# Resize the buffer pool, and check that the syslogger continues to run while
# the resize is in progress.
# TODO: Instead of custom markers we could use the log line that is emitted when
# the resize is complete, when we have frozen those.
for my $dir (['expand', $expanded_nbuffers], ['shrink', $initial_nbuffers])
{
	my ($name, $target) = @$dir;

	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");
	is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"),
		't',
		"$name to $target succeeds with syslogger running");
	ok(check_syslogger_running("syslogger_marker_after_$name"),
		"syslogger drains logs after $name");
}

done_testing();
