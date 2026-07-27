# Copyright (c) 2025-2026, PostgreSQL Global Development Group

=pod

=head1 NAME

StressUtil - shared driver for the buffermgr shared_buffers resize stress tests

=head1 SYNOPSIS

  use StressUtil;

  # Configure a stress test driver
  my $stress = StressUtil->new(
      buffer_sizes => [128, 28, ...],
      application_name => 'pgbench_..._test',
      pgbench_clients => 10,
      pgbench_scale => 10,
      pgbench_duration => 120,
      injection_points => [...],           # optional
  );

  # Setup the cluster and pgbench workload
  $stress->setup;

  # -- per-test prep goes here; may use $stress->node --

  # Run the stress test with optional custom workload and perform post-stress
  # checks
  $stress->run(
      default_load_weight => 1,            # required if workload_sql set
      workload_sql => $sql,                # optional
      workload_weight => 10,               # required if workload_sql set
  );

=head1 DESCRIPTION

StressUtil provides common routines for the shared_buffers resize stress tests.
These are the routines for setting up the cluster and pgbench database, resizing
shared_buffers in a tight loop while a pgbench workload runs concurrently, and
performing post-stress checks.

=cut

package StressUtil;

use strict;
use warnings FATAL => 'all';

use IPC::Run;
use List::Util qw(max min shuffle);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

=pod

=head1 METHODS

=over

=item StressUtil->new(%opts)

Construct a stress-test object which can be used to run the stress test with the
given specifications. Named options:

=over

=item buffer_sizes

Array reference of shared_buffers values (in number of buffers) that the resize
loop cycles through.  Required.

=item application_name

application_name string set on the pgbench connection; the resize loop
polls pg_stat_activity for this value to detect when pgbench has
exited.  Required.

=item injection_points

Array reference of injection point names used to detect whether a code path is
hit during stress test. They are attached with the B<notice> action. Number of
times the notice message appears in the server error log indicates the number of
times a certain code path is hit during the stress test. Defaults to the empty
list. Used only when the build supports injection points.

=item pgbench_clients

Number of pgbench client connections.  Split evenly across the persistent and
per-transaction pgbench processes, so must be at least B<2>.  May be overridden
at run time by the C<PG_TEST_RESIZE_STRESS_CLIENTS> environment variable.

=item pgbench_scale

pgbench scale factor.  May be overridden at run time by the
C<PG_TEST_RESIZE_STRESS_SCALE> environment variable.

=item pgbench_duration

pgbench duration in seconds.  May be overridden at run time by the
C<PG_TEST_RESIZE_STRESS_SECONDS> environment variable so that the test never
hits the timeout in a successful run.

=back

=cut

sub new
{
	my ($class, %opts) = @_;
	for my $required (
		qw(buffer_sizes
		application_name
		pgbench_clients
		pgbench_scale
		pgbench_duration))
	{
		defined $opts{$required} or die "$required required";
	}

	# Env vars override the test-specified values.
	my $duration =
	  int($ENV{PG_TEST_RESIZE_STRESS_SECONDS} // $opts{pgbench_duration});
	my $clients =
	  int($ENV{PG_TEST_RESIZE_STRESS_CLIENTS} // $opts{pgbench_clients});
	my $scale =
	  int($ENV{PG_TEST_RESIZE_STRESS_SCALE} // $opts{pgbench_scale});

	my $timeout_cap = int(($ENV{PG_TEST_TIMEOUT_DEFAULT} // 0) * 0.8);
	if ($timeout_cap > 0 && $duration > $timeout_cap)
	{
		note "clamping pgbench duration from $duration to $timeout_cap";
		$duration = $timeout_cap;
	}

	$clients >= 2
	  or die "pgbench_clients must be at least 2 "
	  . "(split between persistent and per-transaction pgbench)";

	my $self = {
		buffer_sizes => $opts{buffer_sizes},
		application_name => $opts{application_name},
		pgbench_clients => $clients,
		pgbench_scale => $scale,
		pgbench_duration => $duration,
		injection_points => $opts{injection_points} // [],
		node => undef,
		injection_points_supported => undef,
	};
	return bless $self, $class;
}

=pod

=item $stress->node

Return the underlying C<PostgreSQL::Test::Cluster> node.  Valid only
after setup().

=cut

sub node { return $_[0]->{node}; }

=pod

=item $stress->setup

Create and initialize PostgreSQL cluster and other necessary objects required
for the stress test.

=cut

sub setup
{
	my ($self) = @_;

	my $node = PostgreSQL::Test::Cluster->new('main');
	$node->init;
	$self->{node} = $node;

	my $max_buffer_pool = max @{ $self->{buffer_sizes} };
	my $initial_buffers = min @{ $self->{buffer_sizes} };
	my $ips_supported = ($ENV{enable_injection_points} // 'no') eq 'yes';
	my $use_ips = $ips_supported && @{ $self->{injection_points} };
	$self->{injection_points_supported} = $ips_supported;

	$node->append_conf(
		'postgresql.conf', qq{
max_shared_buffers = $max_buffer_pool
shared_buffers = $initial_buffers
log_statement = none
restart_after_crash = off
});

	# Route injection-point NOTICEs to the server log, not to the pgbench
	# client which does not expect them.
	if ($use_ips)
	{
		$node->append_conf(
			'postgresql.conf', qq{
shared_preload_libraries = injection_points
log_min_messages = notice
client_min_messages = warning
});
	}

	$node->start;

	# Bail out if this build does not support resizable shared memory, which
	# also means that resizing buffer pool is not supported.
	if ($node->safe_psql('postgres', 'SHOW have_resizable_shmem') ne 'on')
	{
		plan skip_all =>
		  "resizable shared memory not supported by this build";
	}

	$node->safe_psql('postgres', "CREATE EXTENSION buffermgr_test");
	$node->safe_psql('postgres', "CREATE EXTENSION amcheck");

	if ($use_ips)
	{
		$node->safe_psql('postgres', "CREATE EXTENSION injection_points");
	}

	# Create a table to capture the history of resizes
	$node->safe_psql(
		'postgres', qq{
CREATE TABLE resize_log(
    size int NOT NULL,
    started_at timestamptz NOT NULL,
    ended_at timestamptz NOT NULL,
    num_tries int NOT NULL);
});

	# Reset the bgwriter stats so we can assert that it ran during the test.
	$node->safe_psql('postgres', "SELECT pg_stat_reset_shared('bgwriter')");
}

=pod

=item $stress->run(%opts)

Run the stress test. This resizes shared_buffers repeatedly while a pgbench
workload runs concurrently. Perform post-stress checks.

Two pgbench processes run in parallel: one keeps its connections open for the
whole run (persistent), the other reconnects for every transaction.  The
C<pgbench_clients> count is split evenly between them.  Each pgbench is passed a
distinct C<pgbench_id> variable and gets a distinct application_name so custom
workloads can build names that do not collide across the two.

pgbench always runs its built-in tpcb-like workload; an optional custom
workload is added if requested.

Named options:

=over

=item workload_sql

Contents of a custom pgbench workload script. Optional.

=item workload_weight

Weight of the custom workload script relative to the built-in
tpcb-like script.  Required when C<workload_sql> is set; must not be
set otherwise.

=item default_load_weight

Weight of the built-in tpcb-like workload relative to the custom
workload script.  Required when C<workload_sql> is set; must not be
set otherwise.

=back

=cut

sub run
{
	my ($self, %opts) = @_;
	my $node = $self->{node} or die "setup() must be called first";
	my $ips = $self->{injection_points};
	my $use_ips = $self->{injection_points_supported} && @$ips;

	my @pgbench_args;

	my $workload_path;
	if (defined $opts{workload_sql})
	{
		my $default_weight = $opts{default_load_weight}
		  // die "default_load_weight required when workload_sql is set";
		my $workload_weight = $opts{workload_weight}
		  // die "workload_weight required when workload_sql is set";

		push @pgbench_args, '-b', "tpcb-like\@$default_weight";

		$workload_path = $node->basedir . '/workload.sql';
		open(my $wfh, '>', $workload_path)
		  or die "cannot write $workload_path: $!";
		print $wfh $opts{workload_sql};
		close($wfh);
		push @pgbench_args, '-f', "$workload_path\@$workload_weight";
	}
	elsif (defined $opts{default_load_weight}
		|| defined $opts{workload_weight})
	{
		die "default_load_weight and workload_weight require workload_sql";
	}

	# Attach injection points just before starting the workload.
	if ($use_ips)
	{
		for my $ip (@$ips)
		{
			$node->safe_psql('postgres',
				"SELECT injection_points_attach('$ip', 'notice')");
		}
	}

	my $log_offset = -s $node->logfile;

	my @procs = _start_pgbench_workloads($self, \@pgbench_args);

	_wait_for_pgbench_ready($node, $self->{application_name});

	my $tests_completed = _run_resize_loop($self);

	_run_post_checks($self, \@procs, $log_offset, $workload_path,
		$tests_completed);
}

=back

=cut

# Resize the buffer pool and log the outcome to resize_log.
sub _apply_and_verify_buffer_change
{
	my ($node, $new_size) = @_;

	$node->safe_psql('postgres',
		"ALTER SYSTEM SET shared_buffers = '$new_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	# Start a new backend so that it inherits the reloaded GUC directly from the
	# postmaster.
	$node->safe_psql(
		'postgres', qq{
		INSERT INTO resize_log(size, started_at, ended_at, num_tries)
		SELECT $new_size, started_at, ended_at, num_tries
		FROM pg_resize_shared_buffers_sql($new_size)
	});

	# A resize failure causes the test to time out, so reaching here means
	# success.
	ok(1, "buffer pool resized to $new_size");
}

# Return true if either pgbench workload is still running, false otherwise.
#
# IPC::Run's pumpable status is unreliable; check pg_stat_activity instead.
sub _pgbench_processes_active
{
	my ($node, $application_name) = @_;

	my $result = $node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity "
		  . "WHERE application_name LIKE '${application_name}%'");
	return int($result) > 0;
}

# Wait until at least one pgbench workload has registered in
# pg_stat_activity, so the resize loop's first _pgbench_processes_active
# check does not race pgbench startup and exit immediately.
sub _wait_for_pgbench_ready
{
	my ($node, $application_name) = @_;

	$node->poll_query_until('postgres',
			"SELECT count(*) >= 1 FROM pg_stat_activity "
		  . "WHERE application_name LIKE '${application_name}%'")
	  or die "timed out waiting for pgbench workloads to connect";
}

# Initialize pgbench, then start two pgbench workloads in parallel: one
# persistent, one with -C (per_transaction).  Clients are split evenly.  Each
# pgbench gets a distinct application_name and a distinct :pgbench_id script
# variable so custom workloads can build non-colliding names across the two.
#
# Returns a list of per-process hashes with keys process, stdout_ref,
# stderr_ref, pgbench_id.
sub _start_pgbench_workloads
{
	my ($self, $extra_args) = @_;
	my $node = $self->{node};
	my $scale = $self->{pgbench_scale};
	my $app_name = $self->{application_name};
	my $total_clients = $self->{pgbench_clients};

	$node->pgbench(
		"--initialize --init-steps=dtpvg --scale=$scale --quiet",
		0,
		[qr{^$}],
		[
			qr{dropping old tables},
			qr{creating tables},
			qr{done in \d+\.\d\d s }
		],
		"pgbench initialization (scale=$scale)");

	my @flavors = (
		{ pgbench_id => 1, extra => [] },
		{ pgbench_id => 2, extra => ['-C'] },);
	my $clients_1 = int($total_clients / 2);
	my $clients_2 = $total_clients - $clients_1;
	$flavors[0]->{clients} = $clients_1;
	$flavors[1]->{clients} = $clients_2;

	my @procs;
	for my $f (@flavors)
	{
		my $id = $f->{pgbench_id};
		my $flavor_app = "${app_name}_${id}";
		my ($stdin, $stdout, $stderr) = ('', '', '');
		my $process = IPC::Run::start(
			[
				'pgbench',
				'-p', $node->port,
				'-h', $node->host,
				'-T', $self->{pgbench_duration},
				'-c', $f->{clients},
				'-D', "pgbench_id=$id",
				# stop on first server crash, so that conditions at the time of
				# crash are preserved for diagnosis.
				'--exit-on-abort',
				'--continue-on-error',
				@{ $f->{extra} },
				@$extra_args,
				"dbname=postgres application_name=$flavor_app"
			],
			'<' => \$stdin,
			'>' => \$stdout,
			'2>' => \$stderr);

		ok($process, "pgbench started successfully (pgbench_id=$id)");
		push @procs,
		  {
			process => $process,
			stdout_ref => \$stdout,
			stderr_ref => \$stderr,
			pgbench_id => $id,
		  };
	}
	return @procs;
}

# Resize as many times as possible while pgbench is running, cycling
# through $self->{buffer_sizes} in a shuffled order without ever picking
# the same size twice in a row.  Returns the number of resizes performed.
sub _run_resize_loop
{
	my ($self) = @_;
	my $node = $self->{node};
	my $app_name = $self->{application_name};
	my $buffer_sizes = $self->{buffer_sizes};
	my @queue;
	my $last_picked;
	my $tests_completed = 0;

	while (_pgbench_processes_active($node, $app_name))
	{
		if (!@queue)
		{
			@queue = shuffle(@$buffer_sizes);
			if (defined $last_picked
				&& @queue > 1
				&& $queue[0] == $last_picked)
			{
				@queue[0, 1] = @queue[1, 0];
			}
		}
		$last_picked = shift @queue;
		_apply_and_verify_buffer_change($node, $last_picked);
		$tests_completed++;
	}
	return $tests_completed;
}

# Assert the resize loop ran through at least one full sequence and
# every size in @$buffer_sizes was picked at least once.
sub _assert_all_sizes_used
{
	my ($node, $buffer_sizes, $tests_completed) = @_;

	cmp_ok($tests_completed, '>', scalar(@$buffer_sizes),
		"all buffer size transitions were tested");
	note
	  "completed $tests_completed buffer resize operations while pgbench was running";

	my $ndistinct = $node->safe_psql('postgres',
		"SELECT count(DISTINCT size) FROM resize_log");
	is($ndistinct, scalar(@$buffer_sizes),
		"every buffer size was exercised at least once");
}

# Make sure that the pgbench workloads have ended and perform post-stress
# checks.
sub _run_post_checks
{
	my ($self, $procs, $log_offset, $workload_path, $tests_completed) = @_;

	my $node = $self->{node};
	my $ips = $self->{injection_points};

	for my $p (@$procs)
	{
		my $id = $p->{pgbench_id};
		$p->{process}->signal('TERM');
		ok((IPC::Run::finish $p->{process}),
			"pgbench finished successfully (pgbench_id=$id)");
		note("pgbench_id=$id stderr:\n" . ${ $p->{stderr_ref} })
		  if ${ $p->{stderr_ref} } ne '';
		note("pgbench_id=$id stdout:\n" . ${ $p->{stdout_ref} });
	}

	_assert_all_sizes_used($node, $self->{buffer_sizes}, $tests_completed);

	# Log resize latency distribution and max retry count, for post-mortem
	note $node->safe_psql(
		'postgres',
		q{SELECT format('resize stats: n=%s, min=%s, avg=%s, max=%s, max_tries=%s',
              count(*),
              min(ended_at - started_at),
              avg(ended_at - started_at),
              max(ended_at - started_at),
              max(num_tries))
		FROM resize_log});

	# Checkpointer activity, for post-mortem.
	note $node->safe_psql(
		'postgres',
		q{SELECT format('checkpointer stats: timed=%s, requested=%s, buffers_written=%s',
              num_timed, num_requested, buffers_written)
		FROM pg_stat_checkpointer});

	is( $node->safe_psql(
			'postgres', "SELECT buffers_clean > 0 FROM pg_stat_bgwriter"),
		't',
		"background writer ran during resize cycle");

	# Server error log is expected to be crash free
	$node->log_check("no PANIC or SIGBUS during stress run",
		$log_offset, log_unlike => [ qr/PANIC/, qr/signal 7/ ]);

	# pg_dumpall reads every table and catalog in every database; An error free
	# dump indicates that the database remained non-corrupt after the stress
	# run. We are not interested in the dump output, so discard it to /dev/null.
	$node->command_ok(
		[ 'pg_dumpall', '--no-sync', '-f', '/dev/null' ],
		"pg_dumpall succeeds after stress run");

	# pg_dumpall does not scan indexes; run bt_index_parent_check over every
	# btree index to catch index-level corruption.
	$node->safe_psql(
		'postgres', q{
		SELECT bt_index_parent_check(c.oid, true, true)
		  FROM pg_class c
		  JOIN pg_index i ON i.indexrelid = c.oid
		 WHERE c.relkind = 'i'
		   AND c.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
	});
	ok(1, "all btree indexes verified");

	# Verify tables
	my $heap_findings = $node->safe_psql(
		'postgres', q{
		SELECT count(*)
		  FROM (SELECT c.oid AS rel
		          FROM pg_class c
		         WHERE c.relkind IN ('r', 'S')
		           AND c.relpersistence = 'p') r,
		       LATERAL verify_heapam(r.rel, check_toast => true) v
	});
	is($heap_findings, '0', "verify_heapam found no corruption");

	if (@$ips)
	{
	  SKIP:
		{
			skip "injection points not supported by this build"
			  unless $self->{injection_points_supported};

			my $workload_txns = 0;
			for my $p (@$procs)
			{
				my $n;
				if (defined $workload_path)
				{
					($n) = ${ $p->{stdout_ref} } =~
					  m{SQL script \d+:\s+\Q$workload_path\E.*?number of transactions actually processed:\s*(\d+)}s;
				}
				else
				{
					($n) = ${ $p->{stdout_ref} } =~
					  m{number of transactions actually processed:\s*(\d+)};
				}
				ok( defined $n,
					"transaction count found in pgbench stdout (pgbench_id="
					  . $p->{pgbench_id} . ")");
				$workload_txns += $n if defined $n;
			}

			my $log_content = slurp_file($node->logfile, $log_offset);
			for my $ip (@$ips)
			{
				my $count = () = $log_content =~
				  /notice triggered for injection point $ip\b/g;
				cmp_ok($count, '>=', $workload_txns,
					"injection point $ip fired at least $workload_txns times"
				);
			}
		}
	}
}

1;
