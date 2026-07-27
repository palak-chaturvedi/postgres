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
      injection_points => [...],           # optional
  );

  # Setup the cluster and pgbench workload
  $stress->setup;

  # -- per-test prep goes here; may use $stress->node --

  # Run the stress test with optional custom workload and perform post-stress
  # checks
  $stress->run(
      workload_sql => $sql,                # optional
      default_load_weight => 1,            # optional
      client_mode => 'per_transaction',    # optional
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
use List::Util qw(max shuffle);
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

=item initial_shared_buffers

Value of shared_buffers used to start the cluster.  Defaults to B<16>.

=item injection_points

Array reference of injection point names used to detect whether a code path is
hit during stress test. They are attached with the B<notice> action. Number of
times the notice message appears in the server error log indicates the number of
times a certain code path is hit during the stress test. Defaults to the empty
list. Used only when the build supports injection points.

=item pgbench_clients

Number of pgbench client connections.  Required.

=item pgbench_scale

Scale factor passed to C<pgbench --initialize>.  Required.

=item pgbench_duration

Duration in seconds passed to pgbench via B<-T>.  Required.

=back

=cut

sub new
{
	my ($class, %opts) = @_;
	for my $required (qw(buffer_sizes
						 application_name
						 pgbench_clients
						 pgbench_scale
						 pgbench_duration))
	{
		defined $opts{$required} or die "$required required";
	}
	my $self = {
		buffer_sizes => $opts{buffer_sizes},
		application_name => $opts{application_name},
		pgbench_clients => $opts{pgbench_clients},
		pgbench_scale => $opts{pgbench_scale},
		pgbench_duration => $opts{pgbench_duration},
		initial_shared_buffers => $opts{initial_shared_buffers} // 16,
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
	my $ips_supported = ($ENV{enable_injection_points} // 'no') eq 'yes';
	my $use_ips = $ips_supported && @{ $self->{injection_points} };
	$self->{injection_points_supported} = $ips_supported;

	$node->append_conf(
		'postgresql.conf', qq{
max_shared_buffers = $max_buffer_pool
shared_buffers = $self->{initial_shared_buffers}
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
	$node->safe_psql('postgres', "CREATE EXTENSION buffermgr_test");

	if ($use_ips)
	{
		$node->safe_psql('postgres', "CREATE EXTENSION injection_points");
	}

	# Create a table to capture the history of resizes
	$node->safe_psql('postgres', qq{
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

pgbench always runs its built-in tpcb-like workload; an optional custom workload
is also run if provided.

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

=item client_mode

B<persistent> (default) reuses one connection per client for the whole
run.  B<per_transaction> passes B<-C> to pgbench, so each transaction
opens a new backend; this maximises the chance of a backend attaching
while a resize is in flight.

=back

=cut

sub run
{
	my ($self, %opts) = @_;
	my $node = $self->{node} or die "setup() must be called first";
	my $ips = $self->{injection_points};
	my $use_ips = $self->{injection_points_supported} && @$ips;
	my $client_mode = $opts{client_mode} // 'persistent';

	my @pgbench_args;
	if ($client_mode eq 'per_transaction')
	{
		push @pgbench_args, '-C';
	}
	elsif ($client_mode ne 'persistent')
	{
		die "unknown client_mode: $client_mode";
	}

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

	# Attach the injection points and capture the log offset just before
	# starting the workload.
	my $log_offset = 0;
	if ($use_ips)
	{
		for my $ip (@$ips)
		{
			$node->safe_psql('postgres',
				"SELECT injection_points_attach('$ip', 'notice')");
		}
		$log_offset = -s $node->logfile;
	}

	my ($process, $stdout_ref, $stderr_ref) =
	  _start_pgbench_workload($self, \@pgbench_args);

	my $tests_completed = _run_resize_loop($self);

	_run_post_checks($self, $process, $stdout_ref, $stderr_ref,
		$log_offset, $workload_path, $tests_completed);
}

=back

=cut

# Resize the buffer pool and log the outcome to resize_log.
sub _apply_and_verify_buffer_change
{
	my ($node, $new_size) = @_;

	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$new_size'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	# Start a new backend so that it inherits the reloaded GUC directly from the
	# postmaster.
	$node->safe_psql('postgres', qq{
		INSERT INTO resize_log(size, started_at, ended_at, num_tries)
		SELECT $new_size, started_at, ended_at, num_tries
		FROM pg_resize_shared_buffers_sql($new_size)
	});

	# A resize failure causes the test to time out, so reaching here means
	# success.
	ok(1, "buffer pool resized to $new_size");
}

# Return true if the pgbench workload is still running, false otherwise.
# 
# IPC::Run's pumpable status is unreliable; check pg_stat_activity
# instead.
sub _pgbench_processes_active
{
	my ($node, $application_name) = @_;

	my $result = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE application_name = '$application_name';"
	);
	return int($result) > 0;
}

# Initialize pgbench and start the workload. Returns handle to the IPC::Run
# process and references to its stdout and stderr of pgbench process.
sub _start_pgbench_workload
{
	my ($self, $extra_args) = @_;
	my $node = $self->{node};
	my $scale = $self->{pgbench_scale};
	my $app_name = $self->{application_name};

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

	my ($stdin, $stdout, $stderr) = ('', '', '');
	my $process = IPC::Run::start(
		[
			'pgbench',
			'-p', $node->port,
			'-h', $node->host,
			'-T', $self->{pgbench_duration},
			'-c', $self->{pgbench_clients},
			# stop on first server crash or error
			'--exit-on-abort',
			'--continue-on-error',
			@$extra_args,
			"dbname=postgres application_name=$app_name"
		],
		'<' => \$stdin,
		'>' => \$stdout,
		'2>' => \$stderr);

	ok($process, "pgbench started successfully");
	return ($process, \$stdout, \$stderr);
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

	my $ndistinct = $node->safe_psql('postgres', "SELECT count(DISTINCT size) FROM resize_log");
	is($ndistinct, scalar(@$buffer_sizes), "every buffer size was exercised at least once");
}

# Make sure that the pgbench has ended and perform post-stress checks.
sub _run_post_checks
{
	my ($self, $process, $stdout_ref, $stderr_ref, $log_offset,
		$workload_path, $tests_completed) = @_;

	my $node = $self->{node};
	my $ips = $self->{injection_points};

	$process->signal('TERM');
	ok((IPC::Run::finish $process), "pgbench finished successfully");
	note("pgbench stderr:\n" . $$stderr_ref);
	note("pgbench stdout:\n" . $$stdout_ref);

	_assert_all_sizes_used($node, $self->{buffer_sizes}, $tests_completed);

	# Log resize latency distribution and max retry count, for post-mortem
	note $node->safe_psql('postgres',
	q{SELECT format('resize stats: n=%s, min=%s, avg=%s, max=%s, max_tries=%s',
              count(*),
              min(ended_at - started_at),
              avg(ended_at - started_at),
              max(ended_at - started_at),
              max(num_tries))
		FROM resize_log});

	is($node->safe_psql('postgres', "SELECT buffers_clean > 0 FROM pg_stat_bgwriter"),
	   't',
	   "background writer ran during resize cycle");

	if (@$ips)
	{
	  SKIP:
		{
			skip "injection points not supported by this build"
			  unless $self->{injection_points_supported};

			my $workload_txns;
			if (defined $workload_path)
			{
				($workload_txns) = $$stdout_ref =~
				  m{SQL script \d+:\s+\Q$workload_path\E.*?number of transactions actually processed:\s*(\d+)}s;
			}
			else
			{
				($workload_txns) = $$stdout_ref =~
				  m{number of transactions actually processed:\s*(\d+)};
			}
			ok(defined $workload_txns,
				"transaction count found in pgbench stdout");

			my $log_content = slurp_file($node->logfile, $log_offset);
			for my $ip (@$ips)
			{
				my $count =
				  () = $log_content =~ /notice triggered for injection point $ip\b/g;
				cmp_ok($count, '>=', $workload_txns,
					"injection point $ip fired at least $workload_txns times");
			}
		}
	}

	# TODO: Instead of just checking that the database is still accessible, we
	# should also check the integrity of the data in the database after all the
	# buffer changes. This could involve running some queries to verify that the
	# expected data is still present and correct. Palak has developed some tests
	# on these lines, pick those up from her PR.
	$node->connect_ok("dbname=postgres",
		"database remains accessible after $tests_completed buffer resize operations"
	);
}

1;
