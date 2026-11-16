-- Read-only preview. Run after 95 and 96. can_archive=false must be reviewed separately.
select * from public.preview_launch_test_cleanup() order by can_archive,table_name,row_id;
