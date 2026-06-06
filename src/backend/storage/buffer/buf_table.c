/*-------------------------------------------------------------------------
 *
 * buf_table.c
 *	  routines for mapping BufferTags to buffer indexes.
 *
 * Note: the routines in this file do no locking of their own.  The caller
 * must hold a suitable lock on the appropriate BufMappingLock, as specified
 * in the comments.  We can't do the locking inside these functions because
 * in most cases the caller needs to adjust the buffer header contents
 * before the lock is released (see notes in README).
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/buf_table.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "funcapi.h"
#include "storage/buf_internals.h"
#include "utils/rel.h"
#include "utils/builtins.h"
#include "storage/lwlock.h"
#include "storage/subsystems.h"
#include "storage/pg_shmem.h"

/* entry for buffer lookup hashtable */
typedef struct
{
	BufferTag	key;			/* Tag of a disk page */
	int			id;				/* Associated buffer ID */
} BufferLookupEnt;

static HTAB *SharedBufHash;

static void BufTableShmemRequest(void *arg);

const ShmemCallbacks BufTableShmemCallbacks = {
	.request_fn = BufTableShmemRequest,
	/* no special initialization needed, the hash table will start empty */
};

/*
 * Register shmem hash table for mapping buffers.
 *		size is the desired hash table size (possibly more than the size of the buffer pool).
 */
void
BufTableShmemRequest(void *arg)
{
	int			size;

	/*
	 * Request the shared buffer lookup hashtable.
	 *
	 * Since we can't tolerate running out of lookup table entries, we must be
	 * sure to specify an adequate table size here. The maximum number of
	 * entries we could need is the number of buffers, but BufferAlloc() tries
	 * to insert a new entry before deleting the old.  In principle this could
	 * be happening in each partition concurrently, so we could need as many
	 * as (number of buffers) + NUM_BUFFER_PARTITIONS entries. The number of
	 * buffers can be increased upto MaxNBuffers at run time. So we need to
	 * make sure that the table can accommodate MaxNBuffers +
	 * NUM_BUFFER_PARTITIONS entries.
	 *
	 * See storage/buffer/README for reasons why we don't register the hash
	 * table as a resizable structure.
	 *
	 */
#ifdef HAVE_RESIZABLE_SHMEM
	size = (shared_memory_type == SHMEM_TYPE_MMAP) ? MaxNBuffers : NBuffersGUC;
#else
	size = NBuffersGUC;
#endif
	size = size + NUM_BUFFER_PARTITIONS;

	ShmemRequestHash(.name = "Shared Buffer Lookup Table",
					 .nelems = size,
					 .ptr = &SharedBufHash,
					 .hash_info.keysize = sizeof(BufferTag),
					 .hash_info.entrysize = sizeof(BufferLookupEnt),
					 .hash_info.num_partitions = NUM_BUFFER_PARTITIONS,
					 .hash_flags = HASH_ELEM | HASH_BLOBS | HASH_PARTITION | HASH_FIXED_SIZE,
		);
}

/*
 * BufTableHashCode
 *		Compute the hash code associated with a BufferTag
 *
 * This must be passed to the lookup/insert/delete routines along with the
 * tag.  We do it like this because the callers need to know the hash code
 * in order to determine which buffer partition to lock, and we don't want
 * to do the hash computation twice (hash_any is a bit slow).
 */
uint32
BufTableHashCode(BufferTag *tagPtr)
{
	return get_hash_value(SharedBufHash, tagPtr);
}

/*
 * BufTableLookup
 *		Lookup the given BufferTag; return buffer ID, or -1 if not found
 *
 * Caller must hold at least share lock on BufMappingLock for tag's partition
 */
int
BufTableLookup(BufferTag *tagPtr, uint32 hashcode)
{
	BufferLookupEnt *result;

	result = (BufferLookupEnt *)
		hash_search_with_hash_value(SharedBufHash,
									tagPtr,
									hashcode,
									HASH_FIND,
									NULL);

	if (!result)
		return -1;

	return result->id;
}

/*
 * BufTableInsert
 *		Insert a hashtable entry for given tag and buffer ID,
 *		unless an entry already exists for that tag
 *
 * Returns -1 on successful insertion.  If a conflicting entry exists
 * already, returns the buffer ID in that entry.
 *
 * Caller must hold exclusive lock on BufMappingLock for tag's partition
 */
int
BufTableInsert(BufferTag *tagPtr, uint32 hashcode, int buf_id)
{
	BufferLookupEnt *result;
	bool		found;

	Assert(buf_id >= 0);		/* -1 is reserved for not-in-table */
	Assert(tagPtr->blockNum != P_NEW);	/* invalid tag */

	result = (BufferLookupEnt *)
		hash_search_with_hash_value(SharedBufHash,
									tagPtr,
									hashcode,
									HASH_ENTER,
									&found);

	if (found)					/* found something already in the table */
		return result->id;

	result->id = buf_id;

	return -1;
}

/*
 * BufTableDelete
 *		Delete the hashtable entry for given tag (which must exist)
 *
 * Caller must hold exclusive lock on BufMappingLock for tag's partition
 */
void
BufTableDelete(BufferTag *tagPtr, uint32 hashcode)
{
	BufferLookupEnt *result;

	result = (BufferLookupEnt *)
		hash_search_with_hash_value(SharedBufHash,
									tagPtr,
									hashcode,
									HASH_REMOVE,
									NULL);

	if (!result)				/* shouldn't happen */
		elog(ERROR, "shared buffer hash table corrupted");
}

/*
 * BufTableGetContents
 *		Fill the given tuplestore with contents of the shared buffer lookup table
 *
 * This function is used by pg_buffercache extension to expose buffer lookup
 * table contents via SQL. The caller is responsible for setting up the
 * tuplestore and result set info.
 */
void
BufTableGetContents(Tuplestorestate *tupstore, TupleDesc tupdesc)
{
/* Expected number of attributes of the buffer lookup table entry. */
#define BUFTABLE_CONTENTS_COLS 6

	HASH_SEQ_STATUS hstat;
	BufferLookupEnt *ent;
	Datum		values[BUFTABLE_CONTENTS_COLS];
	bool		nulls[BUFTABLE_CONTENTS_COLS];
	int			i;

	memset(nulls, 0, sizeof(nulls));

	Assert(tupdesc->natts == BUFTABLE_CONTENTS_COLS);

	/*
	 * Lock all buffer mapping partitions to ensure a consistent view of the
	 * hash table during the scan. Must grab LWLocks in partition-number order
	 * to avoid LWLock deadlock.
	 */
	for (i = 0; i < NUM_BUFFER_PARTITIONS; i++)
		LWLockAcquire(BufMappingPartitionLockByIndex(i), LW_SHARED);

	hash_seq_init(&hstat, SharedBufHash);
	while ((ent = (BufferLookupEnt *) hash_seq_search(&hstat)) != NULL)
	{
		values[0] = ObjectIdGetDatum(ent->key.spcOid);
		values[1] = ObjectIdGetDatum(ent->key.dbOid);
		values[2] = ObjectIdGetDatum(ent->key.relNumber);
		values[3] = ObjectIdGetDatum(ent->key.forkNum);
		values[4] = Int64GetDatum(ent->key.blockNum);
		values[5] = Int32GetDatum(ent->id);

		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	}

	/*
	 * Release all buffer mapping partition locks in the reverse order so as
	 * to avoid LWLock deadlock.
	 */
	for (i = NUM_BUFFER_PARTITIONS - 1; i >= 0; i--)
		LWLockRelease(BufMappingPartitionLockByIndex(i));
}
