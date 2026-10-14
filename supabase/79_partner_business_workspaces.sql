-- Representative workspace selection. Staff access is intentionally not enabled here.
begin;

create or replace function public.list_own_business_workspaces()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'partner'
      and p.status in ('approved', 'pending')
  ) then
    raise exception '사장님 계정으로 로그인해 주세요.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'business_name', b.business_name,
    'business_type', b.business_type,
    'approval_status', b.approval_status,
    'can_open', b.approval_status = 'approved'
      or (b.import_job_id is not null and b.approval_status in ('pending', 'rejected'))
  ) order by (b.approval_status = 'approved') desc, b.created_at, b.id), '[]'::jsonb)
  into result
  from public.businesses b
  where b.owner_id = auth.uid();
  return result;
end;
$$;

revoke all on function public.list_own_business_workspaces() from public, anon;
grant execute on function public.list_own_business_workspaces() to authenticated;

commit;
