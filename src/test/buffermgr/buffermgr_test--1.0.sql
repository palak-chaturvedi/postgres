-- Helper functions used by TAP tests in src/test/buffermgr/t.
--

\echo Use "CREATE EXTENSION buffermgr_test" to load this file. \quit

-- Retries pg_resize_shared_buffers() until it succeeds, then confirms the
-- new value is in effect. Returns the number of retries taken along with
-- the wall-clock times immediately before and after the retry loop.
--
-- The new size is expected to be set in shared_buffers GUC before calling this
-- function.
create function pg_resize_shared_buffers_sql(
    new_size int,
    out num_tries int,
    out started_at timestamptz,
    out ended_at timestamptz)
returns record as $$
declare
    success boolean := false;
    tries int := 0;
    cur_setting text;
    target text := new_size::text;
    pending_pattern text := '%(pending: ' || target || ')%';
begin
    select setting into cur_setting
    from pg_settings where name = 'shared_buffers';
    if cur_setting <> target and cur_setting not like pending_pattern then
        raise exception 'shared_buffers change not visible to this backend: setting is %, expected % or matching %',
            cur_setting, target, pending_pattern;
    end if;

    started_at := clock_timestamp();
    while not success loop
        tries := tries + 1;
        select pg_resize_shared_buffers() into success;
        if not success then
            perform pg_sleep(0.1);
        end if;
    end loop;
    ended_at := clock_timestamp();

    select setting into cur_setting
    from pg_settings where name = 'shared_buffers';
    if cur_setting <> target then
        raise exception 'shared_buffers resize did not take effect: expected %, got %',
            target, cur_setting;
    end if;

    num_tries := tries;
    return;
end;
$$ language plpgsql;
