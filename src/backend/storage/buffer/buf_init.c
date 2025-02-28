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

BufferDescPadded *BufferDescriptors;
char	   *BufferBlocks;
ConditionVariableMinimallyPadded *BufferIOCVArray;
WritebackContext BackendWritebackContext;
CkptSortItem *CkptBufferIds;


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
 * Initialize shared buffer pool
 *
 * This is called once during shared-memory initialization (either in the
 * postmaster, or in a standalone backend). Size of data structures initialized
 * here depends on NBuffers, and to be able to change NBuffers without a
 * restart we store each structure into a separate shared memory segment, which
 * could be resized on demand.
 */
void
BufferManagerShmemInit(void)
{
	bool		foundBufs,
				foundDescs,
				foundIOCV,
				foundBufCkpt;

	/* Align descriptors to a cacheline boundary. */
	BufferDescriptors = (BufferDescPadded *)
		ShmemInitStructInSegment("Buffer Descriptors",
								 NBuffers * sizeof(BufferDescPadded),
								 &foundDescs, BUFFER_DESCRIPTORS_SHMEM_SEGMENT);

	/* Align buffer pool on IO page size boundary. */
	BufferBlocks = (char *)
		TYPEALIGN(PG_IO_ALIGN_SIZE,
				  ShmemInitStructInSegment("Buffer Blocks",
										   NBuffers * (Size) BLCKSZ + PG_IO_ALIGN_SIZE,
										   &foundBufs, BUFFERS_SHMEM_SEGMENT));

	/* Align condition variables to cacheline boundary. */
	BufferIOCVArray = (ConditionVariableMinimallyPadded *)
		ShmemInitStructInSegment("Buffer IO Condition Variables",
								 NBuffers * sizeof(ConditionVariableMinimallyPadded),
								 &foundIOCV, BUFFER_IOCV_SHMEM_SEGMENT);

	/*
	 * The array used to sort to-be-checkpointed buffer ids is located in
	 * shared memory, to avoid having to allocate significant amounts of
	 * memory at runtime. As that'd be in the middle of a checkpoint, or when
	 * the checkpointer is restarted, memory allocation failures would be
	 * painful.
	 */
	CkptBufferIds = (CkptSortItem *)
		ShmemInitStructInSegment("Checkpoint BufferIds",
								 NBuffers * sizeof(CkptSortItem), &foundBufCkpt,
								 CHECKPOINT_BUFFERS_SHMEM_SEGMENT);

	if (foundDescs || foundBufs || foundIOCV || foundBufCkpt)
	{
		/* should find all of these, or none of them */
		Assert(foundDescs && foundBufs && foundIOCV && foundBufCkpt);
		/* note: this path is only taken in EXEC_BACKEND case */
	}
	else
	{
		int			i;

		/*
		 * Initialize all the buffer headers.
		 */
		for (i = 0; i < NBuffers; i++)
		{
			BufferDesc *buf = GetBufferDescriptor(i);

			ClearBufferTag(&buf->tag);

			pg_atomic_init_u64(&buf->state, 0);
			buf->wait_backend_pgprocno = INVALID_PROC_NUMBER;

			buf->buf_id = i;

			pgaio_wref_clear(&buf->io_wref);

			proclist_init(&buf->lock_waiters);
			ConditionVariableInit(BufferDescriptorGetIOCV(buf));
		}
	}

	/* Init other shared buffer-management stuff */
	StrategyInitialize(!foundDescs);

	/* Initialize per-backend file flush context */
	WritebackContextInit(&BackendWritebackContext,
						 &backend_flush_after);
}

/*
 * BufferManagerShmemSize
 *
 * compute the size of shared memory for the buffer pool including
 * data pages, buffer descriptors, hash tables, etc. based on the
 * shared memory segment. The main segment must not allocate anything
 * related to buffers, every other segment will receive part of the
 * data.
 */
Size
BufferManagerShmemSize(MemoryMappingSizes *mapping_sizes)
{
	size_t		size;

	/* size of buffer descriptors, plus alignment padding */
	size = add_size(0, mul_size(NBuffers, sizeof(BufferDescPadded)));
	size = add_size(size, PG_CACHE_LINE_SIZE);
	mapping_sizes[BUFFER_DESCRIPTORS_SHMEM_SEGMENT].shmem_req_size = size;
	mapping_sizes[BUFFER_DESCRIPTORS_SHMEM_SEGMENT].shmem_reserved = size;

	/* size of data pages, plus alignment padding */
	size = add_size(0, PG_IO_ALIGN_SIZE);
	size = add_size(size, mul_size(NBuffers, BLCKSZ));
	mapping_sizes[BUFFERS_SHMEM_SEGMENT].shmem_req_size = size;
	mapping_sizes[BUFFERS_SHMEM_SEGMENT].shmem_reserved = size;

	/* size of stuff controlled by freelist.c */
	mapping_sizes[STRATEGY_SHMEM_SEGMENT].shmem_req_size = StrategyShmemSize();
	mapping_sizes[STRATEGY_SHMEM_SEGMENT].shmem_reserved = StrategyShmemSize();

	/* size of I/O condition variables, plus alignment padding */
	size = add_size(0, mul_size(NBuffers,
								sizeof(ConditionVariableMinimallyPadded)));
	size = add_size(size, PG_CACHE_LINE_SIZE);
	mapping_sizes[BUFFER_IOCV_SHMEM_SEGMENT].shmem_req_size = size;
	mapping_sizes[BUFFER_IOCV_SHMEM_SEGMENT].shmem_reserved = size;

	/* size of checkpoint sort array in bufmgr.c */
	mapping_sizes[CHECKPOINT_BUFFERS_SHMEM_SEGMENT].shmem_req_size = mul_size(NBuffers, sizeof(CkptSortItem));
	mapping_sizes[CHECKPOINT_BUFFERS_SHMEM_SEGMENT].shmem_reserved = mul_size(NBuffers, sizeof(CkptSortItem));

	return size;
}
