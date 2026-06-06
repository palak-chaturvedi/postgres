-- Test buffer pool resizing and shared memory allocation tracking This test
-- resizes the buffer pool multiple times and monitors shared memory allocations
-- related to buffer management

-- TODOs
--
-- 1. The test sets shared_buffers values in MBs. Instead it could use values in
-- kBs so that the test runs on very small machines.
--
-- 2. The size, minimum_size and maximum_size columns in pg_shmem_allocations
-- for "Buffer Blocks" should be same as the value of GUC shared_buffers. We
-- should test that.
--
-- 3. We should make sure that when the shared_buffers value is increased, the
-- size and allocated_size for all buffer related shared memory allocations
-- increases and when the shared_buffers value is decreased, the size and
-- allocated_size for all buffer related shared memory allocations decreases
-- proportionately.
--
-- 4. allocated_size for allocations should be greater than or equal to size for
-- all buffer related shared memory allocations. Similarly reserved_space should
-- be greater than or equal to maximum_size for all buffer related shared memory
-- allocations. We should test these conditions as well.

CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- Load test_shmem for test_shmem_pagesize().
CREATE EXTENSION IF NOT EXISTS test_shmem;

-- Create a view for buffer-related shared memory allocations
CREATE VIEW buffer_allocations AS
SELECT name, size,
       allocated_size >= size AS alloc_size_cmp,
       allocated_size - size < 2 * test_shmem_pagesize() AS alloc_size_diff,
       minimum_size, maximum_size, reserved_space
FROM pg_shmem_allocations
WHERE name IN ('Buffer Blocks', 'Buffer Descriptors', 'Buffer IO Condition Variables',
               'Checkpoint BufferIds')
ORDER BY name;

-- Test 1: Default shared_buffers
SHOW shared_buffers;
SHOW max_shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;
-- Calling pg_resize_shared_buffers() without changing shared_buffers should be a no-op.
SELECT pg_resize_shared_buffers();
SHOW shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;

-- Test 2: Set to 64MB
ALTER SYSTEM SET shared_buffers = '64MB';
SELECT pg_reload_conf();
-- reconnect to ensure new setting is loaded
\c
SHOW shared_buffers;
SELECT pg_resize_shared_buffers();
SHOW shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;

-- Test 3: Set to 256MB
ALTER SYSTEM SET shared_buffers = '256MB';
SELECT pg_reload_conf();
-- reconnect to ensure new setting is loaded
\c
SHOW shared_buffers;
SELECT pg_resize_shared_buffers();
SHOW shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;

-- Test 4: Set to 100MB (non-power-of-two)
ALTER SYSTEM SET shared_buffers = '100MB';
SELECT pg_reload_conf();
-- reconnect to ensure new setting is loaded
\c
SHOW shared_buffers;
SELECT pg_resize_shared_buffers();
SHOW shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;

-- Test 5: Set to minimum 128kB
ALTER SYSTEM SET shared_buffers = '128kB';
SELECT pg_reload_conf();
-- reconnect to ensure new setting is loaded
\c
SHOW shared_buffers;
SELECT pg_resize_shared_buffers();
SHOW shared_buffers;
SELECT * FROM buffer_allocations;
SELECT COUNT(*) AS buffer_count FROM pg_buffercache;

-- Test 6: Try to set shared_buffers higher than max_shared_buffers (should fail)
ALTER SYSTEM SET shared_buffers = '400MB';
SELECT pg_reload_conf();
-- reconnect to ensure new setting is loaded
\c
-- This should show the old value since the configuration was rejected
SHOW shared_buffers;
SHOW max_shared_buffers;

-- TODO: Test that a non-superuser can not invoke pg_resize_shared_buffers()
-- function.
