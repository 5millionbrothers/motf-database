-- Execute ONLY after reviewing 96A. No physical deletion, no PG cancellation.
begin;
select public.archive_launch_verified_tests() as archived_test_rows;
commit;
