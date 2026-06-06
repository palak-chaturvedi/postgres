/*-------------------------------------------------------------------------
 *
 * buf_resize.c
 *	  shared buffer pool resizing functionality
 *
 * This module contains the implementation of shared buffer pool resizing,
 * including the main resize coordination function and barrier processing
 * functions that synchronize all backends during resize operations.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/buf_resize.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/htup_details.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "postmaster/bgwriter.h"
#include "storage/bufmgr.h"
#include "storage/buf_internals.h"
#include "storage/ipc.h"
#include "storage/pg_shmem.h"
#include "storage/pmsignal.h"
#include "storage/procsignal.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/injection_point.h"

static volatile sig_atomic_t safe_exit = true;

static bool resize_shared_buffers_internal(void);
static void buf_resize_shmem_exit(int code, Datum arg);

/*
 * Set the new buffer allocation pool size, broadcast it to all the backends
 * and wait for them to acknowledge it.
 */
static void
buf_resize_set_new_alloc_size(int alloc_size)
{
	uint64		generation;

	pg_atomic_write_u32(&BufferControl->activeNBuffers, alloc_size);
	StrategyAdjustNewBufAllocSize();
	generation = EmitProcSignalBarrier(PROCSIGNAL_BARRIER_NEW_BUFFER_ALLOC);
	INJECTION_POINT("pgrsb-new-buffer-alloc-barrier-sent", NULL);
	WaitForProcSignalBarrier(generation);
	elog(LOG, "all backends acknowledged PROCSIGNAL_BARRIER_NEW_BUFFER_ALLOC barrier");
}

/*
 * Update the buffer pool size, broadcast it to all the backends and wait for
 * them to acknowledge the change.
 */
static void
buf_resize_set_buffer_pool_size(int new_size)
{
	uint64		generation;

	pg_atomic_write_u32(&BufferControl->currentNBuffers, new_size);
	generation = EmitProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_SIZE);
	INJECTION_POINT("pgrsb-buffer-pool-size-barrier-sent", NULL);
	WaitForProcSignalBarrier(generation);
	elog(LOG, "all backends acknowledged PROCSIGNAL_BARRIER_BUFFER_POOL_SIZE barrier");
}

/*
 * Resize the shared buffer manager structures, broadcast the change to all
 * the backends and wait for them to acknowledge it.
 *
 * If memory is not available when expanding the buffer pool, this function
 * returns false without sending the barrier. When shrinking the buffer pool, we
 * don't expect any failure, so this function always returns true.
 */
static bool
buf_resize_shmem_resize(int currentNBuffers, int targetNBuffers)
{
	uint64		generation;

	if (!BufferManagerShmemResize(currentNBuffers, targetNBuffers))
	{
		Assert(targetNBuffers > currentNBuffers);
		return false;
	}

	generation = EmitProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE);
	INJECTION_POINT("pgrsb-buffer-pool-resize-barrier-sent", NULL);
	WaitForProcSignalBarrier(generation);
	elog(LOG, "all backends acknowledged PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE barrier");
	return true;
}

/*
 * C implementation of SQL interface to update the shared buffers according to
 * the current values of shared_buffers GUC.
 *
 * Atomic BufferControl::resizer_pid holds the PID of the backend currently
 * performing a resize, or 0 when no resize is in progress. Using
 * compare-and-exchange to set and reset this field, we make sure that only one
 * resize is in progress at a time.
 *
 * Shrinking the buffer pool involves the following steps:
 * - s1: Set BufferControl::activeNBuffers to the new size of the buffer pool
 *   and send SHBUF_NEW_BUFFER_ALLOC barrier to all backends. Every backend is
 *   expected to update their local buffer allocation pool size and acknowledge
 *   the barrier.
 * - s2: Wait for all backends to acknowledge the barrier. When all backends
 *   have acknowledged the barrier, new buffer allocations will be restricted
 *   to the new size of the buffer pool.
 * - s3: Evict the buffers beyond the new size. A backend which still requires
 *   a previously allocated buffer which is being evicted, must have pinned it.
 *   If a pinned buffer is encountered, the resize operation is rolled back and
 *   the function returns false.
 * - s4: If eviction succeeds, no backend should be using the buffers beyond
 *   the new size of the buffer pool and no new buffers can be allocated in
 *   that range. Update BufferControl::currentNBuffers to the new size of the
 *   buffer pool and send SHBUF_BUFFER_POOL_SIZE barrier to all backends. In
 *   response, all the backends should update their local buffer pool size and
 *   acknowledge the barrier.
 * - s5: Wait for all backends to acknowledge the barrier. When all backends
 *   have acknowledged the barrier, no backend will be accessing the shared
 *   buffer manager structures beyond the new size of the buffer pool.
 * - s6: Resize the shared buffer manager structures to the new size (using
 *   ShmemResizeStruct()) and send SHBUF_BUFFER_POOL_RESIZE barrier to all
 *   backends. In response, all the backends should call ShmemProtectStruct()
 *   to update the memory address space protection of the shared buffer
 *   manager structures.
 * - s7: Wait for all backends to acknowledge the barrier, before returning
 *   true to indicate successful resizing.
 *
 * Expanding the buffer pool involves the following steps:
 * - e1: Resize the shared buffer manager structures to the new size (using
 *   ShmemResizeStruct()) and send SHBUF_BUFFER_POOL_RESIZE barrier to all the
 *   backends. In response, all the backends should call ShmemProtectStruct()
 *   to update the memory address space protection of the shared buffer
 *   manager structures. If expanding the shared buffer manager structures
 *   fails because of lack of memory, the function returns false without
 *   sending the barrier.
 * - e2: Wait for all backends to acknowledge the barrier. When all backends
 *   have acknowledged the barrier, every backend will be able to access the
 *   shared buffer manager structures beyond the old size of the buffer pool.
 * - e3: Update BufferControl::currentNBuffers to the new size of the buffer
 *   pool and send SHBUF_BUFFER_POOL_SIZE barrier to all backends. In response,
 *   all the backends should update their local buffer pool size and
 *   acknowledge the barrier.
 * - e4: Wait for all backends to acknowledge the barrier. When all backends
 *   have acknowledged the barrier, every backend is setup to use the new size
 *   of the buffer pool.
 * - e5: Update BufferControl::activeNBuffers to the new size of the buffer
 *   pool, so that backends can start allocating from the new area of the
 *   buffer pool. Send SHBUF_NEW_BUFFER_ALLOC barrier to all backends. In
 *   response, all the backends should update their local buffer allocation
 *   pool size and acknowledge the barrier.
 * - e6: Wait for all backends to acknowledge the barrier, before returning
 *   true to indicate successful resizing.
 *
 * Reason we introduce e4:
 * Once we expand the new buffer allocation area, all the backends will start
 * allocating buffers from the new area. Since this happens asynchronously,
 * there is a chance that some backends may see buffers from outside their
 * known buffer pool size. To avoid that, first set the new buffer pool size,
 * broadcast it to all the backends and wait for them to update their
 * knowledge of buffer pool size.  We may be able to avoid sending the barrier
 * after the first step or avoid them altogether but it's not clear that that
 * is completely hazard free. It feels safer this way, even though it takes
 * longer.
 *
 * If a timeout happens or request to cancel query arrives while the function is
 * being executed, we need to abort the operation immediately. The state of the
 * buffer pool and its state as viewed by the backends may not be consistent at
 * that point. Hence we escalate it to PANIC to restart the server and avoid
 * inconsistent state. We may improve this situation by leaving the buffer pool
 * in a consistent but degenerate state and allowing a subsequent resize
 * operation to rollback or continue the operation.
 *
 * If an ERROR is raised while the function is being executed, we may have
 * already entered an inconsistent state. Hence we escalate it to PANIC to
 * restart the server and avoid inconsistent state.
 */
Datum
pg_resize_shared_buffers(PG_FUNCTION_ARGS)
{
	bool		success = false;

	/*
	 * Register the exit hook before claiming resizer_pid, so that if we exit
	 * after claiming resizer_pid, the hook is in place to reset it.
	 */
	before_shmem_exit(buf_resize_shmem_exit, 0);

	PG_TRY();
	{
		uint32		expected_pid = 0;

		if (!pg_atomic_compare_exchange_u32(&BufferControl->resizer_pid,
											&expected_pid, MyProcPid))
		{
			/*
			 * Another backend holds resizer_pid; expected_pid was updated by
			 * the CAS to reflect its PID.
			 */
			elog(LOG, "shared buffer resize already in progress in backend %u",
				 expected_pid);
			/* No shared memory was touched, so it should be safe to exit. */
			Assert(safe_exit);
		}
		else
		{
			INJECTION_POINT("pg-resize-shared-buffers-flag-set", NULL);

			/*
			 * We are about to make changes to the shared memory which can not
			 * be rolled back easily since we need all the backends to
			 * acknowledge these changes. Indicate that a sudden exit in this
			 * state can leave the server in an inconsistent state.
			 */
			safe_exit = false;
			success = resize_shared_buffers_internal();

			/*
			 * The changes to shared memory are in a consistent state across
			 * all the backends, so it should be safe to exit.
			 */
			safe_exit = true;
		}
	}
	PG_FINALLY();
	{
		uint32		expected_pid = MyProcPid;

		/*
		 * We are in the middle of resizing and caught an error. Without
		 * knowing the reason and exact state of resizing it's not safe to
		 * continue or to exit. Restarting the server is the safest option
		 * here.  Emit the error to the server log and raise PANIC to restart
		 * the server.
		 */
		if (!safe_exit)
		{
			HOLD_INTERRUPTS();
			errcontext("during shared buffer resize");
			EmitErrorReport();
			ereport(PANIC,
					errmsg("shared buffer resize caught an error when shared memory was in an inconsistent state"));
			pg_unreachable();
		}

		/*
		 * Reset the PID, if we set it before removing the shmem_exit hook so
		 * as not to leave it set after the backend has exited.
		 */
		(void) pg_atomic_compare_exchange_u32(&BufferControl->resizer_pid,
											  &expected_pid, 0);
		cancel_before_shmem_exit(buf_resize_shmem_exit, 0);
	}
	PG_END_TRY();

	if (success)
		elog(LOG, "shared buffer resizing to %d buffers completed successfully", NBuffersGUC);
	else
		elog(WARNING, "shared buffer resizing to %d buffers failed", NBuffersGUC);

	PG_RETURN_BOOL(success);
}

/*
 * Workhorse function for the C implementation.
 */
static bool
resize_shared_buffers_internal(void)
{
	int			currentNBuffers;
	int			targetNBuffers;
	bool		resize_success;

	currentNBuffers = pg_atomic_read_u32(&BufferControl->currentNBuffers);
	targetNBuffers = NBuffersGUC;
	if (currentNBuffers == targetNBuffers)
	{
		elog(LOG, "shared buffers are already at %d, no need to resize", currentNBuffers);
		return true;
	}

	/*
	 * TODO: What if the NBuffersGUC value seen here is not the desired one
	 * because somebody did a pg_reload_conf() between the last
	 * pg_reload_conf() and execution of this function?
	 */

	pg_atomic_write_u32(&BufferControl->targetNBuffers, targetNBuffers);
	elog(LOG, "resizing shared buffers from %d to %d", currentNBuffers, targetNBuffers);

	if (targetNBuffers < currentNBuffers)
	{
		/*
		 * step s1, s2: Restrict new buffer allocations to the new buffer pool
		 * size.
		 *
		 * TODO: Alternate design idea by Andres (as I understand it): Set
		 * BufferControl::activeNBuffers and send the barrier. Instead of
		 * waiting for barrier, start evicting buffers but don't unpin the
		 * evicted buffers so that they will not be considered for new
		 * allocations. Once all the buffers are evicted wait for the barrier
		 * to be acknowledged. This will reduce the time taken to shrink the
		 * buffer pool.
		 */
		elog(LOG, "shrinking buffer pool, restricting allocations to %d buffers", targetNBuffers);
		buf_resize_set_new_alloc_size(targetNBuffers);

		/* Step s3: Evict buffers in the area being shrunk */
		elog(LOG, "evicting buffers %u..%u", targetNBuffers + 1, currentNBuffers);
		if (!EvictExtraBuffers(targetNBuffers, currentNBuffers))
		{
			elog(WARNING, "failed to evict extra buffers during shrinking");

			/* Eviction failed, rollback the buffer resize operation. */
			pg_atomic_write_u32(&BufferControl->targetNBuffers, currentNBuffers);
			buf_resize_set_new_alloc_size(currentNBuffers);
			return false;
		}

		/* Step s4, s5: Update the buffer pool size. */
		buf_resize_set_buffer_pool_size(targetNBuffers);
	}

	/* Step s6, s7 or e1, e2: Resize the buffer manager structures. */
	resize_success = buf_resize_shmem_resize(currentNBuffers, targetNBuffers);

	if (targetNBuffers > currentNBuffers)
	{
		if (!resize_success)
		{
			elog(WARNING, "failed to expand buffer pool structures");

			/* Revert any changes to the shared memory in this function. */
			pg_atomic_write_u32(&BufferControl->targetNBuffers, currentNBuffers);
			return false;
		}

		/* Step e3, e4: Declare new buffer pool size. */
		buf_resize_set_buffer_pool_size(targetNBuffers);

		/* Step e5, e6: Let expanded buffer pool be used by all backends. */
		buf_resize_set_new_alloc_size(targetNBuffers);
	}

	return true;
}

/*
 * Function to handle process exit when buffer resizing is in progress.
 */
static void
buf_resize_shmem_exit(int code, Datum arg)
{
	uint32		expected_pid;

	/*
	 * If resizer_pid does not match our PID, either we never claimed it or we
	 * have already released it. Nothing to do.
	 */
	if (pg_atomic_read_u32(&BufferControl->resizer_pid) != MyProcPid)
		return;

	/*
	 * Resize is in progress and the process crashed. We do not know exactly
	 * at which step of the resizing we are. Just restart the server to be
	 * safe.
	 *
	 * TODO: If we can perform heavy operations in this callback like waiting
	 * for barriers, we could set the current status of resizing in the
	 * process local memory and use this callback to rollback every operation
	 * that was performed, except buffer eviction.
	 */
	if (!safe_exit)
		ereport(PANIC,
				errmsg("buffer resize operation interrupted, restarting to avoid inconsistent state"));

	/*
	 * safe_exit should be set to true when new allocations are not using the
	 * whole buffer pool, so the following condition should never happen. But
	 * be on the safer side.
	 */
	if (pg_atomic_read_u32(&BufferControl->currentNBuffers) != pg_atomic_read_u32(&BufferControl->activeNBuffers))
		ereport(PANIC,
				(errmsg("buffer resize operation interrupted at an unexpected stage, restarting to avoid inconsistent state")));

	/*
	 * Reset targetNBuffers before releasing resizer_pid, so that a backend
	 * claiming ownership immediately afterwards does not have its own
	 * targetNBuffers overwritten by us.
	 */
	pg_atomic_write_u32(&BufferControl->targetNBuffers, pg_atomic_read_u32(&BufferControl->currentNBuffers));

	expected_pid = MyProcPid;
	(void) pg_atomic_compare_exchange_u32(&BufferControl->resizer_pid,
										  &expected_pid, 0);
}

/*
 * Process and acknowledge PROCSIGNAL_BARRIER_NEW_BUFFER_ALLOC.
 */
bool
ProcessBarrierNewBufferAlloc(void)
{
	elog(DEBUG2, "processing barrier to restrict new buffer allocations to %d buffers (target = %d)",
		 pg_atomic_read_u32(&BufferControl->activeNBuffers), pg_atomic_read_u32(&BufferControl->targetNBuffers));

	INJECTION_POINT("pgrsb-handle-new-buffer-alloc-barrier", NULL);

	Assert(pg_atomic_read_u32(&BufferControl->resizer_pid) != 0);

	Assert(NBuffers == pg_atomic_read_u32(&BufferControl->currentNBuffers));
	activeNBuffers = pg_atomic_read_u32(&BufferControl->activeNBuffers);

	return true;
}

/*
 * Process and acknowledge PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE.
 */
bool
ProcessBarrierBufferPoolResize(void)
{
	elog(DEBUG2, "processing barrier to propagate resized shared buffer pool structures");

	INJECTION_POINT("pgrsb-handle-buffer-pool-resize-barrier", NULL);

	Assert(pg_atomic_read_u32(&BufferControl->resizer_pid) != 0);

	Assert(NBuffers == pg_atomic_read_u32(&BufferControl->currentNBuffers));
	Assert(activeNBuffers == pg_atomic_read_u32(&BufferControl->activeNBuffers));

	/*
	 * Access permissions to address range covered by a resizable structure is
	 * maintained consistently across all the backends right from the time a
	 * backend is started. We maintain that consistency as the buffer pool is
	 * resized.So ideally modifying the access permissions in this backend
	 * should not fail. But if it does, the address space accessible to this
	 * backend may be inconsistent with the new buffer pool size and also with
	 * the other backends. This may cause data corruption and other memory
	 * access issues, if we let this backend continue to run and access the
	 * buffer pool. Better to quit from the faulty backend.
	 */
	PG_TRY();
	{
		BufferManagerShmemProtect();
	}
	PG_CATCH();
	{
		/*
		 * We don't know what caused the error and so avoid using further
		 * resources. Emit the original error to the server log so that it's
		 * not lost and raise a FATAL to terminate this backend.
		 */
		HOLD_INTERRUPTS();
		errcontext("during shared buffer pool resize barrier");
		EmitErrorReport();
		ereport(FATAL,
				(errmsg("shared buffer pool resize barrier caught an error while updating buffer pool protection")));
		pg_unreachable();
	}
	PG_END_TRY();

	return true;
}

/*
 * Process and acknowledge PROCSIGNAL_BARRIER_BUFFER_POOL_SIZE.
 */
bool
ProcessBarrierBufferPoolSize(void)
{
	elog(DEBUG2, "processing barrier to establish new size of the buffer pool to %d", pg_atomic_read_u32(&BufferControl->currentNBuffers));

	INJECTION_POINT("pgrsb-handle-buffer-pool-size-barrier", NULL);

	Assert(pg_atomic_read_u32(&BufferControl->resizer_pid) != 0);

	Assert(activeNBuffers == pg_atomic_read_u32(&BufferControl->activeNBuffers));
	NBuffers = pg_atomic_read_u32(&BufferControl->currentNBuffers);

	return true;
}

/*
 * SQL-callable function reporting the current shared buffer pool resize
 * status.
 */
Datum
pg_get_buffer_resize_status(PG_FUNCTION_ARGS)
{
#define PG_GET_BUFFER_RESIZE_STATUS_COLS	4
	TupleDesc	tupdesc;
	Datum		values[PG_GET_BUFFER_RESIZE_STATUS_COLS];
	bool		nulls[PG_GET_BUFFER_RESIZE_STATUS_COLS] = {0};
	HeapTuple	tuple;

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);

	values[0] = Int32GetDatum((int32) pg_atomic_read_u32(&BufferControl->activeNBuffers));
	values[1] = Int32GetDatum((int32) pg_atomic_read_u32(&BufferControl->currentNBuffers));
	values[2] = Int32GetDatum((int32) pg_atomic_read_u32(&BufferControl->targetNBuffers));
	values[3] = Int32GetDatum((int32) pg_atomic_read_u32(&BufferControl->resizer_pid));

	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
#undef PG_GET_BUFFER_RESIZE_STATUS_COLS
}

/*
 * TODO: add progress report facility if required.
 */
