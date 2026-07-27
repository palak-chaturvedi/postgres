# Copyright (c) 2025-2025, PostgreSQL Global Development Group
#
# Test that only one pg_resize_shared_buffers() call succeeds when multiple
# sessions attempt to resize buffers concurrently

use strict;
use warnings;
use Config;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Skip this test if injection points are not supported
if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

# =============================================================================
# Initialization
# =============================================================================
my $initial_nbuffers = 16;
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', 'shared_preload_libraries = injection_points');
$node->append_conf('postgresql.conf', "shared_buffers = $initial_nbuffers");
$node->append_conf('postgresql.conf', 'max_shared_buffers = 32');
$node->append_conf('postgresql.conf', 'restart_after_crash = on');
$node->start;

# Load injection points extension for test coordination
$node->safe_psql('postgres', "CREATE EXTENSION injection_points");

# =============================================================================
# Helper functions
# =============================================================================

# Setup resize operation to be interrupted.
#
# Prepare to resize the buffer pool to a target size. Start a resize session
# through a background psql session.  Adjust GUCs for the mode of interruption.
# If injection point is provided, setup it up with the injection point and wait
# for the resize session to reach the injection point.  The resize session is
# returned to the caller.
sub start_resize_session
{
	my ($target_nbuffers, $mode, $injection_point) = @_;

	$node->safe_psql('postgres', "ALTER SYSTEM SET shared_buffers = '$target_nbuffers'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");

	my $session = $node->background_psql('postgres', on_error_stop => 0);

	my $injection_action;
	if (defined $injection_point)
	{
		$injection_action = ($mode eq 'error') ? 'error' : 'wait';
		$session->query_safe('SELECT injection_points_set_local()', verbose => 0);
		$session->query_safe(
			"SELECT injection_points_attach('$injection_point', '$injection_action')",
			verbose => 0);
	}

	apply_session_gucs_for_mode($session, $mode);

	$session->query_until(
		qr/starting_resize/,
		q(
			\echo starting_resize
			SELECT pg_resize_shared_buffers();
		));

	# Wait for the pg_resize_shared_buffers to start waiting at the injection
	# point.
	if (defined $injection_point && $injection_action eq 'wait')
	{
		my $resize_pid = $session->{backend_pid};
		$node->poll_query_until('postgres',
			"SELECT wait_event = '$injection_point' FROM pg_stat_activity WHERE pid = $resize_pid")
		  or die "timed out waiting for resize backend $resize_pid at $injection_point";
	}

	return $session;
}

# Start a backend which can be used to test the barrier handler fault tolerance.
# We use a long pg_sleep() to simulate a load that checks for interrupts
# regularly. The given injection point is attached to the peer backend locally
# to induce a fault in barrier handler.
sub start_peer_session_with_injection_point
{
	my ($injection_point, $action) = @_;

	my $session = $node->background_psql('postgres', on_error_stop => 0);

	$session->query_safe('SELECT injection_points_set_local()', verbose => 0);
	$session->query_safe("SELECT injection_points_attach('$injection_point', '$action')",
		verbose => 0);
	$session->query_until(
		qr/starting_sleep/,
		q(
			\echo starting_sleep
			SELECT pg_sleep(60);
		));

	my $peer_pid = $session->{backend_pid};
	$node->poll_query_until('postgres',
		"SELECT wait_event = 'PgSleep' FROM pg_stat_activity WHERE pid = $peer_pid")
	  or die "timed out waiting for peer $peer_pid to enter pg_sleep";

	return $session;
}

# Apply per-mode session GUCs locally in the given session if required.
sub apply_session_gucs_for_mode
{
	my ($session, $mode) = @_;

	# In timeout mode, set a statement timeout long enough for the resizing
	# session to reach the injection point and stay there but short enough that
	# the test doesn't take too long to fail if something goes wrong.
	if ($mode eq 'timeout')
	{
		$session->query_safe("SET statement_timeout = '500ms'", verbose => 0);
	}

	# Let the resize session detect a client disconnection when testing client
	# disconnections.
	if ($mode eq 'disconnect')
	{
		$session->query_safe("SET client_connection_check_interval = '100ms'",
			verbose => 0);
	}
}

# Administer the interrupt corresponding to $mode against a resize session
# that is waiting to be interrupted while resizing the buffer pool.
sub interrupt_resize_session
{
	my ($mode, $session) = @_;

	if ($mode eq 'terminate')
	{
		$node->safe_psql('postgres', "SELECT pg_terminate_backend(" . $session->{backend_pid} . ")");
	}
	elsif ($mode eq 'cancel')
	{
		$node->safe_psql('postgres', "SELECT pg_cancel_backend(" . $session->{backend_pid} . ")");
	}
	elsif ($mode eq 'disconnect')
	{
		$session->{run}->kill_kill;
	}
	elsif ($mode eq 'timeout')
	{
		# Nothing to do; statement_timeout will fire from within the resize
		# session itself.
	}
	elsif ($mode eq 'error')
	{
		# Nothing to do; the injection point raised ERROR from within the
		# resize backend itself.
	}
	else
	{
		die "interrupt_resize_session: unknown mode '$mode'";
	}
}

# Function to perform checks after the resize operation has been interrupted. As
# a result of the interruption, the resize function may finish rolling back the
# resize or the backend executing that function may exit rolling back the resize
# or the postmaster may restart all the backends. Perform appropriate checks by
# detecting the post-interrupt state.
#
#  - sentinel_session: a background psql session that is used to detect whether the
#    postmaster restarted all backends or not.
#  - resize_session: the background psql session that was executing the resize
#    operation and was interrupted.
#  - log_offset: the offset in the server log file before the resize operation was
#    initiated.
#  - injection_point and mode: the injection point and mode of interruption that
#    was used to interrupt the resize operation.
#  - orig_nbuffers and target_nbuffers: the original and target buffer sizes for
#    the resize operation.
#  - test_label: a label to create unique test names for different tests
sub check_interrupted_resize
{
	my ($sentinel_session, $resize_session, $log_offset, $mode,
		$injection_point, $orig_nbuffers, $target_nbuffers, $test_label) = @_;

	my $resize_pid = $resize_session->{backend_pid};
	my $sentinel_pid = $sentinel_session->{backend_pid};

	# Wait until the resize backend is no longer running the resize query.
	$node->poll_query_until('postgres',
		"SELECT count(*) = 0 FROM pg_stat_activity "
		  . "WHERE pid = $resize_pid AND state = 'active' "
		  . "AND query LIKE '%pg_resize_shared_buffers%'")
	  or die
	  "timed out waiting for resize backend $resize_pid to finish";

	# Wait for the postmaster to be ready in case it restarted the backends.
	$node->poll_query_until('postgres', 'SELECT true')
	  or die "timed out waiting for postmaster liveliness check";

	# Confirm the resize backend was interrupted by the intended signal.
	# Match against the log line emitted by the resize PID so we don't
	# accidentally pick up an unrelated message.
	my %expected_msg = (
		terminate  => 'terminating connection due to administrator command',
		cancel     => 'canceling statement due to user request',
		timeout    => 'canceling statement due to statement timeout',
		disconnect => 'connection to client lost',
		error      => "error triggered for injection point $injection_point",
	);
	my $log_pattern = qr/\[$resize_pid\][^\n]*\Q$expected_msg{$mode}\E/;

	$node->wait_for_log($log_pattern, $log_offset);
	ok($node->log_contains($log_pattern, $log_offset),
		"$test_label: server log shows expected $mode message from pid $resize_pid"
	);

	my $server_restarted = $node->safe_psql('postgres',
		"SELECT count(*) = 0 FROM pg_stat_activity WHERE pid = $sentinel_pid"
	) eq 't';

	if ($server_restarted)
	{
		# Postmaster restarted all backends; sentinel and resize sessions
		# are dead, just reap their IPC::Run handles.
		$sentinel_session->finish;
		$resize_session->finish;

		is($node->safe_psql('postgres',
			"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
			"$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
			"$test_label: buffer pool reflects target size after crash recovery");

		is($node->safe_psql('postgres',
			"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
			"$target_nbuffers",
			"$test_label: pg_settings reports target size after crash recovery");
	}
	else
	{
		$sentinel_session->quit;
		# The resize session may have exited (e.g. on FATAL or disconnect).
		if ($node->safe_psql('postgres',
				"SELECT count(*) = 1 FROM pg_stat_activity WHERE pid = $resize_pid") eq 't')
		{
			$resize_session->quit;
		}
		else
		{
			$resize_session->finish;
		}

		is($node->safe_psql('postgres',
			"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
			"$orig_nbuffers|$orig_nbuffers|$orig_nbuffers|0",
			"$test_label: buffer resize rolled back after $mode");

		# TODO: Also check that the pg_shmem_allocations values are not changed

		is($node->safe_psql('postgres',
			"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
			"$orig_nbuffers (pending: $target_nbuffers)",
			"$test_label: pg_settings reports pending new value after $mode");

		is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"),
			't',
			"$test_label: resize succeeds after interrupted resize is cleaned up");
	}
}

# =============================================================================
# Concurrent resize test functions
#
# Verify that only one pg_resize_shared_buffers() call can succeed at a time
# using injection points.
# =============================================================================

# Workhorse function:
#
# Make the resize session wait at the given injection point and start another
# concurrent resize session. The concurrent resize should fail.
sub test_concurrent_resize_at_injection_point
{
	my ($injection_point, $target_nbuffers, $test_label) = @_;

	my $session = start_resize_session($target_nbuffers, 'concurrent_resize',
		$injection_point);
	my $resize_pid = $session->{backend_pid};

	is($node->safe_psql('postgres',
		"SELECT resizer_pid FROM pg_get_buffer_resize_status()"),
		"$resize_pid", "$test_label: resizer_pid reports resize backend");

	is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"),
		'f', "$test_label: concurrent resize fails");

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('$injection_point')");

	$session->quit;

	is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
		"$test_label: buffer pool resized to target after wakeup");

	is($node->safe_psql('postgres',
		"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
		"$target_nbuffers",
		"$test_label: pg_settings reports target size after wakeup");
}

# Driver function:
#
# Invoke the workhorse function for different injection points
sub test_concurrent_resize
{
	my @injection_points = (
		'pg-resize-shared-buffers-flag-set',
		'pgrsb-new-buffer-alloc-barrier-sent',
		'pgrsb-buffer-pool-size-barrier-sent',
		'pgrsb-buffer-pool-resize-barrier-sent',
	);

	# Expand then shrink so the pool returns to its starting size.
	my @directions = (['expand', 24], ['shrink', $initial_nbuffers]);

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"buffer pool size is $initial_nbuffers at start");

	for my $point (@injection_points)
	{
		for my $dir (@directions)
		{
			my ($name, $target) = @$dir;

			test_concurrent_resize_at_injection_point($point, $target,
				"$name: $point");
		}
	}

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"buffer pool size is $initial_nbuffers at end");
}

# =============================================================================
# Functions to test resize operation interruption
#
# Verify that an interruption in resize operation does not leave the buffer pool
# in an inconsistent state.
# =============================================================================

# Workhorse function:
#
# Interrupt pg_resize_shared_buffers() when it is waiting on an injection point.
# Check that the buffer pool is left in a consistent state as an aftermath.
#
# $mode selects how the resize session is interrupted.
#  - 'terminate'  - SIGTERM via pg_terminate_backend() from another session.
#  - 'cancel'     - SIGINT via pg_cancel_backend() from another session.
#  - 'timeout'    - statement_timeout fires inside the resize session itself.
#  - 'disconnect' - the resize session's client connection is closed abruptly.
#  - 'error'      - the injection point itself raises ERROR from within the
#                   resize backend.
sub test_interrupt_resize_at_injection_point
{
	my ($injection_point, $target_nbuffers, $mode, $test_label) = @_;

	my $orig_nbuffers = $node->safe_psql('postgres',
		"SELECT current_nbuffers FROM pg_get_buffer_resize_status()");
	my $log_offset = -s $node->logfile;

	# Start a sentinel session that will be used to detect whether the
	# postmaster restarted all backends or not after the resize session is
	# interrupted.
	my $sentinel_session = $node->background_psql('postgres', on_error_stop => 0);

	my $resize_session = start_resize_session($target_nbuffers, $mode,
		$injection_point);

	interrupt_resize_session($mode, $resize_session);

	check_interrupted_resize($sentinel_session, $resize_session, $log_offset,
		$mode, $injection_point, $orig_nbuffers, $target_nbuffers,
		$test_label);
}

# Driver function:
#
# Invoke the workhorse function for different injection points passing it the
# given mode of interruption.
sub test_interrupt_resize_session
{
	my ($mode) = @_;

	my @injection_points = (
		'pg-resize-shared-buffers-flag-set',
		'pgrsb-new-buffer-alloc-barrier-sent',
		'pgrsb-buffer-pool-size-barrier-sent',
		'buffer-mgr-resize-struct',
		'pgrsb-buffer-pool-resize-barrier-sent',
	);

	# Expand then shrink so the pool returns to its starting size.
	my @directions = (['expand', 24], ['shrink', $initial_nbuffers]);

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"$mode: buffer pool size is $initial_nbuffers at start");

	for my $point (@injection_points)
	{
		for my $dir (@directions)
		{
			my ($name, $target) = @$dir;

			test_interrupt_resize_at_injection_point($point, $target, $mode,
				"$mode $name: $point");
		}
	}

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"$mode: buffer pool size is $initial_nbuffers at end");
}

# =============================================================================
# Functions to test error handling in barrier handler
#
# Verify that an error in barrier handler does not cause a resize session to
# fail. The barrier handler may run in a peer backend or the backend which is
# performing the resize itself.
# =============================================================================

# Workhorse function:
#
# Make a peer session wait at the given injection point in the barrier handler
# and simulate an error in the handler.
sub test_error_in_barrier_handler_at_injection_point
{
	my ($injection_point, $target_nbuffers, $test_label) = @_;

	my $peer_session = start_peer_session_with_injection_point($injection_point, 'error');
	my $peer_pid = $peer_session->{backend_pid};

	my $log_offset = -s $node->logfile;

	# Resize the buffer pool which will send a barrier to the peer backend
	# simulating an error in the barrier handler.
	$node->safe_psql('postgres',"ALTER SYSTEM SET shared_buffers = '$target_nbuffers'");
	$node->safe_psql('postgres', "SELECT pg_reload_conf()");
	is($node->safe_psql('postgres', "SELECT pg_resize_shared_buffers()"), 't');

	# Confirm the peer raised the expected error from inside the handler.
	my $log_pattern = qr/\[$peer_pid\][^\n]*\Qerror triggered for injection point $injection_point\E/;
	$node->wait_for_log($log_pattern, $log_offset);
	ok($node->log_contains($log_pattern, $log_offset),
		"$test_label: server log shows error from peer pid $peer_pid at $injection_point"
	);

	# Check that the resize was completed as expected
	is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
		"$test_label: buffer pool reflects target size");

	is($node->safe_psql('postgres',
		"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
		"$target_nbuffers",
		"$test_label: pg_settings reports target size");

	# pg_resize_shared_buffers() returns only after every peer has
	# acknowledged the barrier, so by this point the erroring peer has
	# already left procArray.  Assert that and then reap its IPC::Run handle.
	is($node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity WHERE pid = $peer_pid"),
		'0',
		"$test_label: peer pid $peer_pid exited after handler error");

	$peer_session->finish;
}

# Driver function:
#
# Simulate a failure to change the protection on the shared memory. This should
# cause the barrier handler to raise an error. The barrier handler may run in a
# peer backend or the backend which is performing the resize itself. The resize
# session should still complete successfully.
sub test_error_in_barrier_handler
{
	my $injection_point = 'buffer-mgr-protect-struct';

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"error-in-handler: buffer pool size is $initial_nbuffers at start");

	# Test error in barrier handler in a peer backend.  Expand then shrink so
	# the pool returns to its starting size.
	for my $dir (['expand', 24], ['shrink', $initial_nbuffers])
	{
		my ($name, $target) = @$dir;
		test_error_in_barrier_handler_at_injection_point($injection_point,
			$target, "error-in-handler peer $name");
	}

	# Test the same error in the barrier handler in the resize backend itself.
	# Expand then shrink so the pool returns to its starting size.
	for my $dir (['expand', 24], ['shrink', $initial_nbuffers])
	{
		my ($name, $target) = @$dir;
		test_interrupt_resize_at_injection_point($injection_point,
			$target, 'error', "error-in-handler resize-backend $name");
	}

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"error-in-handler: buffer pool size is $initial_nbuffers at end");
}

# =============================================================================
# Functions to test fault tolerance of resize operation waiting for barrier
#
# Test that, when interrupted, a resizing operation waiting for a barrier to be
# acknowledged doesn't leave the buffer pool in an inconsistent state.
# =============================================================================

# Workhorse function:
#
# We start a peer session with the given injection point in the barrier handler
# code attached locally. Once the resize operation starts, the peer session will
# hit the injection point and wait there. Interrupt the resize session and check
# that the buffer pool is left in a consistent state as an aftermath.
#
# - injection_point: the injection point to attach to the peer session.
# - target_nbuffers: the target buffer size for the resize operation.
# - mode: the mode of interruption to apply to the resize session.
# - test_label: a label to create unique test names for different tests
sub test_fault_resize_waiting_barrier
{
	my ($injection_point, $target_nbuffers, $mode, $test_label) = @_;

	my $orig_nbuffers = $node->safe_psql('postgres',
		"SELECT current_nbuffers FROM pg_get_buffer_resize_status()");
	my $log_offset = -s $node->logfile;

	my $peer_session = start_peer_session_with_injection_point($injection_point, 'wait');
	my $peer_pid = $peer_session->{backend_pid};

	# Sentinel session to detect a postmaster restart.
	my $sentinel_session = $node->background_psql('postgres', on_error_stop => 0);

	my $resize_session = start_resize_session($target_nbuffers, $mode);
	my $resize_pid = $resize_session->{backend_pid};

	# Wait for the peer to reach the injection point. At this point the resize
	# backend should be blocked in WaitForProcSignalBarrier.
	$node->poll_query_until('postgres',
		"SELECT wait_event = '$injection_point' FROM pg_stat_activity WHERE pid = $peer_pid")
	  or die "$test_label: timed out waiting for peer $peer_pid at $injection_point";
	is($node->safe_psql('postgres',
			"SELECT wait_event FROM pg_stat_activity WHERE pid = $resize_pid"),
		'ProcSignalBarrier',
		"$test_label: resize $resize_pid is waiting at ProcSignalBarrier");

	interrupt_resize_session($mode, $resize_session);

	check_interrupted_resize($sentinel_session, $resize_session, $log_offset,
		$mode, $injection_point, $orig_nbuffers, $target_nbuffers, $test_label);

	# Cleanup peer session. If the postmaster restarted all backends, the peer
	# backend is already gone.
	if ($node->safe_psql('postgres',
			"SELECT count(*) = 1 FROM pg_stat_activity WHERE pid = $peer_pid") eq 't')
	{
		$peer_session->quit;
	}
	else
	{
		$peer_session->finish;
	}
}

# Driver function:
#
# Invoke the workhorse function for different injection points passing it the
# given mode of interruption.
sub test_fault_resize_waiting_barrier_for_mode
{
	my ($mode) = @_;

	my @injection_points = (
		'pgrsb-handle-new-buffer-alloc-barrier',
		'pgrsb-handle-buffer-pool-size-barrier',
		'pgrsb-handle-buffer-pool-resize-barrier',
	);

	# Expand then shrink so the pool returns to its starting size.
	my @directions = (['expand', 24], ['shrink', $initial_nbuffers]);

	is($node->safe_psql('postgres', "SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"fault-resize-on-peer $mode: buffer pool size is $initial_nbuffers at start");

	for my $point (@injection_points)
	{
		for my $dir (@directions)
		{
			my ($name, $target) = @$dir;

			test_fault_resize_waiting_barrier($point, $target, $mode,
				"fault-resize-on-peer $mode $name: $point");
		}
	}

	is($node->safe_psql('postgres', "SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"fault-resize-on-peer $mode: buffer pool size is $initial_nbuffers at end");
}

# =============================================================================
# Functions to test server restart during a resize
#
# Verify that a server can be stopped and started while a resize operation is in
# progress and the server is started with buffer pool in a consistent state that
# reflects the target size.
# =============================================================================

# Workhorse function for fast/immediate shutdown:
#
# Make the resize session wait at the given injection point and restart the
# server in the given mode.
sub test_server_restart_during_resize_at_injection_point
{
	my ($injection_point, $target_nbuffers, $stop_mode, $test_label) = @_;

	my $resize_session = start_resize_session($target_nbuffers,
		'server_restart', $injection_point);

	$node->stop($stop_mode);

	# Cleanup resize session, the backend must have gone now.
	$resize_session->finish;

	$node->start;

	is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
		"$test_label: buffer pool reflects target size after $stop_mode restart");

	is($node->safe_psql('postgres',
		"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
		"$target_nbuffers",
		"$test_label: pg_settings reports target size after $stop_mode restart");
}

# Workhorse function for smart shutdown:
#
# Let the resize operation wait at the given injection point, send a smart
# shutdown asynchronously. Once the postmaster enters smart shutdown, wakeup the
# resize backend and let it complete. Verify that the pool reflects the target
# size immediately and also after the restart.
#
# - injection_point: the injection point to park the resize backend at.
# - target_nbuffers: the target buffer size for the resize operation.
# - test_label: a label to create unique test names for different tests
sub test_server_restart_smart_during_resize_at_injection_point
{
	my ($injection_point, $target_nbuffers, $test_label) = @_;

	my $log_offset = -s $node->logfile;

	my $resize_session = start_resize_session($target_nbuffers, 'server_restart', $injection_point);
	my $resize_pid = $resize_session->{backend_pid};

	# Open another session which can be used to wakeup the resize backend.
	my $control_session = $node->background_psql('postgres', on_error_stop => 0);

	# Start the process to stop the server in smart mode.
	local %ENV = $node->_get_env();
	my @stop_cmd = ('pg_ctl', '--pgdata' => $node->data_dir, '--mode' => 'smart', 'stop');
	my ($stop_in, $stop_out, $stop_err) = ('', '', '');
	my $stop_session = IPC::Run::start(\@stop_cmd,
		\$stop_in, \$stop_out, \$stop_err);

	# Confirm the postmaster entered smart shutdown.
	$node->wait_for_log(qr/received smart shutdown request/, $log_offset);

	# Make sure that the resize backend is still alive
	is($control_session->query("SELECT wait_event FROM pg_stat_activity WHERE pid = $resize_pid"),
		$injection_point,
		"$test_label: resize backend alive during smart shutdown");

	# Wake up the resize backnd and let it finish.
	$control_session->query_safe("SELECT injection_points_wakeup('$injection_point')",
		verbose => 0);

	# Check that the resize finished successfully by querying from the same
	# session. The queries won't return if the resize didn't finish. Accomodate
	# the output 't' from pg_resize_shared_buffers() in the expected output of
	# the first query.
	is($resize_session->query("SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()",
			verbose => 0),
		"t\n$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
		"$test_label: pg_resize_shared_buffers() succeeded and pool at target during smart shutdown");
	is($resize_session->query("SELECT setting FROM pg_settings WHERE name = 'shared_buffers'",
			verbose => 0),
		"$target_nbuffers",
		"$test_label: pg_settings reports target size during smart shutdown");

	$resize_session->quit;
	$control_session->quit;

	# Wait for server to stop
	IPC::Run::finish($stop_session)
	  or die "$test_label: pg_ctl smart stop failed: $stop_err";

	# Sync Cluster.pm internal state and start the cluster back.
	$node->{_pid} = undef;
	$node->start;

	is($node->safe_psql('postgres',
		"SELECT active_nbuffers, current_nbuffers, target_nbuffers, resizer_pid FROM pg_get_buffer_resize_status()"),
		"$target_nbuffers|$target_nbuffers|$target_nbuffers|0",
		"$test_label: buffer pool reflects target size after smart restart");

	is($node->safe_psql('postgres',
		"SELECT setting FROM pg_settings WHERE name = 'shared_buffers'"),
		"$target_nbuffers",
		"$test_label: pg_settings reports target size after smart restart");
}

# Driver function:
#
# Invoke the workhorse function for every injection point in resize operation in
# both directions for the given stop mode.
sub test_server_restart_during_resize
{
	my ($stop_mode) = @_;

	my @injection_points = (
		'pg-resize-shared-buffers-flag-set',
		'pgrsb-new-buffer-alloc-barrier-sent',
		'pgrsb-buffer-pool-size-barrier-sent',
		'pgrsb-buffer-pool-resize-barrier-sent',
	);

	# Expand then shrink so the pool returns to its starting size.
	my @directions = (['expand', 24], ['shrink', $initial_nbuffers]);

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"server-restart $stop_mode: buffer pool size is $initial_nbuffers at start");

	for my $point (@injection_points)
	{
		for my $dir (@directions)
		{
			my ($name, $target) = @$dir;
			my $label = "server-restart $stop_mode $name: $point";

			if ($stop_mode eq 'smart')
			{
				test_server_restart_smart_during_resize_at_injection_point(
					$point, $target, $label);
			}
			else
			{
				test_server_restart_during_resize_at_injection_point($point,
					$target, $stop_mode, $label);
			}
		}
	}

	is($node->safe_psql('postgres',
			"SELECT current_nbuffers FROM pg_get_buffer_resize_status()"),
		"$initial_nbuffers",
		"server-restart $stop_mode: buffer pool size is $initial_nbuffers at end");
}

# =============================================================================
# Run tests
# =============================================================================
test_concurrent_resize();
test_error_in_barrier_handler();

test_interrupt_resize_session('terminate');
test_interrupt_resize_session('cancel');
test_interrupt_resize_session('timeout');
test_interrupt_resize_session('error');

# A resize session waiting for a barrier to be acknowledged can not be
# interrupted by an error. Hence don't test that mode.
test_fault_resize_waiting_barrier_for_mode('terminate');
test_fault_resize_waiting_barrier_for_mode('cancel');
test_fault_resize_waiting_barrier_for_mode('timeout');

test_server_restart_during_resize('immediate');
test_server_restart_during_resize('fast');
test_server_restart_during_resize('smart');

# client_connection_check_interval is only effective on systems that expose
# POLLRDHUP/EPOLLRDHUP (Linux, and a few other Unix variants).  On other
# platforms the GUC is silently a no-op, so the disconnect test would hang.
if ($Config::Config{osname} eq 'linux')
{
	test_interrupt_resize_session('disconnect');
	test_fault_resize_waiting_barrier_for_mode('disconnect');
}
else
{
	diag("skipping disconnect interrupt test on $Config::Config{osname} "
		  . "(requires POLLRDHUP support)");
}

done_testing();

# Few more tests to add but may be somewhere else
# TODO: test that a non-superuser cannot run pg_resize_shared_buffers()
