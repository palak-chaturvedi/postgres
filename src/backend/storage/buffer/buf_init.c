/*-------------------------------------------------------------------------
 *
 * buf_init.c
 *	  buffer manager initialization routines
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/buf_init.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "storage/aio.h"
#include "storage/buf_internals.h"
#include "storage/bufmgr.h"
#include "storage/pg_shmem.h"
#include "storage/proclist.h"
#include "storage/shmem.h"
#include "storage/subsystems.h"
#include "utils/guc.h"
#include "utils/guc_hooks.h"
#include "utils/injection_point.h"

BufferControlBlock *BufferControl;
BufferDescPadded *BufferDescriptors;
char	   *BufferBlocks;
ConditionVariableMinimallyPadded *BufferIOCVArray;
WritebackContext BackendWritebackContext;
CkptSortItem *CkptBufferIds;

static void BufferManagerShmemRequest(void *arg);
static void BufferManagerShmemInit(void *arg);
static void BufferManagerShmemAttach(void *arg);

const ShmemCallbacks BufferManagerShmemCallbacks = {
	.request_fn = BufferManagerShmemRequest,
	.init_fn = BufferManagerShmemInit,
	.attach_fn = BufferManagerShmemAttach,
};

/*
 * Resizable shared memory structures backing the buffer pool.
 */
static const struct
{
	const char *name;
	size_t		element_size;
	size_t		alignment;
	void	  **ptr;
}			BufferManagerResizableStructs[] = {

	{"Buffer Descriptors",
		sizeof(BufferDescPadded),
		PG_CACHE_LINE_SIZE,
	(void **) &BufferDescriptors},
	{"Buffer Blocks",
		BLCKSZ,
		PG_IO_ALIGN_SIZE,
	(void **) &BufferBlocks},
	{"Buffer IO Condition Variables",
		sizeof(ConditionVariableMinimallyPadded),
		PG_CACHE_LINE_SIZE,
	(void **) &BufferIOCVArray},
};

/*
 * Data Structures:
 *		buffers live in a freelist and a lookup data structure.
 *
 *
 * Buffer Lookup:
 *		Two important notes.  First, the buffer has to be
 *		available for lookup BEFORE an IO begins.  Otherwise
 *		a second process trying to read the buffer will
 *		allocate its own copy and the buffer pool will
 *		become inconsistent.
 *
 * Buffer Replacement:
 *		see freelist.c.  A buffer cannot be replaced while in
 *		use either by data manager or during IO.
 *
 *
 * Synchronization/Locking:
 *
 * IO_IN_PROGRESS -- this is a flag in the buffer descriptor.
 *		It must be set when an IO is initiated and cleared at
 *		the end of the IO.  It is there to make sure that one
 *		process doesn't start to use a buffer while another is
 *		faulting it in.  see WaitIO and related routines.
 *
 * refcount --	Counts the number of processes holding pins on a buffer.
 *		A buffer is pinned during IO and immediately after a BufferAlloc().
 *		Pins must be released before end of transaction.  For efficiency the
 *		shared refcount isn't increased if an individual backend pins a buffer
 *		multiple times. Check the PrivateRefCount infrastructure in bufmgr.c.
 */

/*
 * Initialize a single buffer.
 */
static void
InitializeBuffer(int buf_id)
{
	/*
	 * Do not use GetBufferDescriptor here since it relies on the buffer
	 * descriptor being initialized.
	 */
	BufferDesc *buf = &(BufferDescriptors[buf_id]).bufferdesc;

	ClearBufferTag(&buf->tag);
	pg_atomic_init_u64(&buf->state, 0);
	buf->wait_backend_pgprocno = INVALID_PROC_NUMBER;
	buf->buf_id = buf_id;
	pgaio_wref_clear(&buf->io_wref);
	proclist_init(&buf->lock_waiters);
	ConditionVariableInit(BufferDescriptorGetIOCV(buf));
}


/*
 * Register shared memory area for the buffer pool.
 */
static void
BufferManagerShmemRequest(void *arg)
{
	/*
	 * Fall back to fixed sized shared buffer pool if resizable shared memory
	 * is not supported on this platform.
	 */
#ifdef HAVE_RESIZABLE_SHMEM
	bool		resizable = (shared_memory_type == SHMEM_TYPE_MMAP);
#else
	bool		resizable = false;
#endif
	int			min_nbuffers = resizable ? MIN_NUM_BUFFERS : 0;
	int			max_nbuffers = resizable ? MaxNBuffers : 0;

	ShmemRequestStruct(.name = "Buffer Control",
					   .size = sizeof(BufferControl),
					   .ptr = (void **) &BufferControl,
		);

	/*
	 * The array used to sort to-be-checkpointed buffer ids is located in
	 * shared memory, to avoid having to allocate significant amounts of
	 * memory at runtime. As that'd be in the middle of a checkpoint, or when
	 * the checkpointer is restarted, memory allocation failures would be
	 * painful.
	 *
	 * When the buffer pool is resizable, it is sized for MaxNBuffers up front
	 * so that the entries filled in by the checkpointer are not freed even
	 * when the buffer pool is shrunk.
	 */
	ShmemRequestStruct(.name = "Checkpoint BufferIds",
					   .size = (size_t) (resizable ? MaxNBuffers : NBuffersGUC) * sizeof(CkptSortItem),
					   .alignment = PG_CACHE_LINE_SIZE,
					   .ptr = (void **) &CkptBufferIds,
		);

	for (int i = 0; i < lengthof(BufferManagerResizableStructs); i++)
	{
		size_t		elem_size = BufferManagerResizableStructs[i].element_size;

		ShmemRequestStruct(.name = BufferManagerResizableStructs[i].name,
						   .minimum_size = min_nbuffers * elem_size,
						   .size = NBuffersGUC * elem_size,
						   .maximum_size = max_nbuffers * elem_size,
						   .alignment = BufferManagerResizableStructs[i].alignment,
						   .ptr = BufferManagerResizableStructs[i].ptr,
			);
	}
}

/*
 * Initialize shared buffer pool
 *
 * This is called once during shared-memory initialization (either in the
 * postmaster, or in a standalone backend).
 */
static void
BufferManagerShmemInit(void *arg)
{
	/*
	 * Set the size of the buffer pool, now that it's allocated and ready to
	 * be initialized.
	 */
	NBuffers = NBuffersGUC;

	/*
	 * Initialize all the buffer headers.
	 */
	for (int i = 0; i < NBuffers; i++)
		InitializeBuffer(i);

	/* Initialize BufferControl */
	pg_atomic_init_u32(&BufferControl->currentNBuffers, NBuffersGUC);
	pg_atomic_init_u32(&BufferControl->activeNBuffers, NBuffersGUC);
	pg_atomic_init_u32(&BufferControl->targetNBuffers, NBuffersGUC);
	pg_atomic_init_u32(&BufferControl->resizer_pid, 0);

	/* Need to perform per backend steps in this backend too. */
	BufferManagerShmemAttach(arg);
}

static void
BufferManagerShmemAttach(void *arg)
{
	/* Initialize per-backend file flush context */
	WritebackContextInit(&BackendWritebackContext,
						 &backend_flush_after);

	BufferManagerInitProc();
}

/*
 * Fetch latest buffer pool sizes (NBuffers and activeNBuffers) shared state
 * into process local globals.
 */
void
BufferManagerInitProc(void)
{
	NBuffers = pg_atomic_read_u32(&BufferControl->currentNBuffers);
	activeNBuffers = pg_atomic_read_u32(&BufferControl->activeNBuffers);

	elog(DEBUG1, "setting process local buffer pool sizes: currentNBuffers = %d, activeNBuffers = %d", NBuffers, activeNBuffers);
}

/*
 * Protect unused shared memory reserved address space.
 *
 * Protect the parts of the shared memory address space reserved by the buffer
 * manager which are not used by current structures from being accessed by
 * backends.
 *
 * Unused address spaces of all resizable shared structures, including the
 * buffer manager ones, are protected at the server startup together using
 * ShmemProtectResizableStructs(). We need this function only during resizing of
 * the buffer pool when we specifically adjust protections of buffer manager
 * structures.
 */
void
BufferManagerShmemProtect(void)
{
	for (int i = 0; i < lengthof(BufferManagerResizableStructs); i++)
	{
		if (i == 2)
			INJECTION_POINT("buffer-mgr-protect-struct", NULL);
		ShmemProtectStruct(BufferManagerResizableStructs[i].name);
	}
}

/*
 * Resize and reinitialize shared buffer manager structures when resizing the
 * buffer pool.
 *
 * Returns true if all the structures were resized successfully, false
 * otherwise. We expect shrink to always succeed, but expansion may fail if the
 * system is out of memory.
 *
 * The caller will always see all the structures resized consistently. If
 * expanding a structure fails, all the expanded structures are shrunk back to
 * their original sizes and no barrier is sent to the other backends.
 */
bool
BufferManagerShmemResize(int currentNBuffers, int targetNBuffers)
{
#ifndef HAVE_RESIZABLE_SHMEM
	ereport(ERROR,
			errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			errmsg("resizing shared buffer pool is not supported on this platform"));
	pg_unreachable();
#else
	int			resized = 0;

	Assert(shared_memory_type == SHMEM_TYPE_MMAP);

	for (int i = 0; i < lengthof(BufferManagerResizableStructs); i++)
	{
		const char *name = BufferManagerResizableStructs[i].name;
		size_t		elem_size = BufferManagerResizableStructs[i].element_size;
		bool		resize_ok = true;

#ifdef USE_INJECTION_POINTS
		if (i == 2)
		{
			/* Injection point to simulate an interruption in this function. */
			INJECTION_POINT("buffer-mgr-resize-struct", NULL);

			/*
			 * Injection point to simulate a failure in resizing a structure
			 * like memory allocation failure without actually running out of
			 * memory.
			 */
			if (IS_INJECTION_POINT_ATTACHED("buffer-mgr-resize-struct-fail"))
				resize_ok = false;
		}
#endif

		if (resize_ok)
			resize_ok = ShmemResizeStruct(name, (size_t) targetNBuffers * elem_size);

		if (!resize_ok)
		{
			Assert(targetNBuffers > currentNBuffers);
			for (int j = 0; j < resized; j++)
				ShmemResizeStruct(BufferManagerResizableStructs[j].name,
								  (size_t) currentNBuffers * BufferManagerResizableStructs[j].element_size);
			return false;
		}
		resized++;
	}

	/* Initialize the headers for new buffers. */
	for (int i = currentNBuffers; i < targetNBuffers; i++)
		InitializeBuffer(i);

	return true;
#endif
}

/*
 * check_shared_buffers
 *		GUC check_hook for shared_buffers
 *
 * When reloading the configuration, shared_buffers should not be set to a value
 * higher than max_shared_buffers fixed at the boot time.
 */
bool
check_shared_buffers(int *newval, void **extra, GucSource source)
{
	if (finalMaxNBuffers && *newval > MaxNBuffers)
	{
		GUC_check_errdetail("\"shared_buffers\" must be less than \"max_shared_buffers\".");
		return false;
	}
	return true;
}

/*
 * show_shared_buffers
 *		GUC show_hook for shared_buffers
 *
 * Shows both current and pending buffer counts with proper unit formatting.
 */
const char *
show_shared_buffers(bool use_units)
{
	static char buffer[128];
	int64		current_value;
	const char *current_unit;
	int			currentNBuffers = pg_atomic_read_u32(&BufferControl->currentNBuffers);

	if (use_units)
		convert_int_from_base_unit(currentNBuffers, GUC_UNIT_BLOCKS, &current_value, &current_unit);
	else
	{
		current_unit = "";
		current_value = currentNBuffers;
	}
	snprintf(buffer, sizeof(buffer), INT64_FORMAT "%s", current_value, current_unit);

	if (currentNBuffers != NBuffersGUC)
	{
		int64		pending_value;
		const char *pending_unit;

		/*
		 * Shared buffer pool is pending to be resized, show both current and
		 * pending sizes.
		 */
		if (use_units)
			convert_int_from_base_unit(NBuffersGUC, GUC_UNIT_BLOCKS, &pending_value, &pending_unit);
		else
		{
			pending_value = NBuffersGUC;
			pending_unit = "";
		}
		snprintf(buffer + strlen(buffer), sizeof(buffer) - strlen(buffer), " (pending: " INT64_FORMAT "%s)",
				 pending_value, pending_unit);
	}

	return buffer;
}
