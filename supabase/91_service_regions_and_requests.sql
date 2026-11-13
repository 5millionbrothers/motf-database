-- Search regions are separate from address-derived administrative regions.
begin;
alter table public.businesses add column if not exists service_regions_initialized boolean not null default false;
create table if not exists public.service_regions (
  id uuid primary key default gen_random_uuid(), name text not null unique check(length(trim(name)) between 1 and 30),
  sort_order integer not null default 0, is_active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.business_service_regions (
  business_id uuid not null references public.businesses(id) on delete cascade,
  region_id uuid not null references public.service_regions(id) on delete restrict,
  primary key(business_id,region_id)
);
create table if not exists public.business_region_requests (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  requested_by uuid references auth.users(id) on delete set null, region_ids uuid[] not null,
  status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
  reason text, review_note text, reviewed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), reviewed_at timestamptz
);
create unique index if not exists one_pending_business_region_request on public.business_region_requests(business_id) where status='pending';
alter table public.service_regions enable row level security;
alter table public.business_service_regions enable row level security;
alter table public.business_region_requests enable row level security;
drop policy if exists region_catalog_read on public.service_regions;
create policy region_catalog_read on public.service_regions for select to anon,authenticated using(is_active or public.is_admin());
drop policy if exists business_region_read on public.business_service_regions;
create policy business_region_read on public.business_service_regions for select to anon,authenticated using(
  exists(select 1 from public.businesses b where b.id=business_id and b.approval_status='approved')
  or case when auth.uid() is null then false else public.is_admin() or public.has_business_permission(business_id,'listing') end
);
drop policy if exists region_request_read on public.business_region_requests;
create policy region_request_read on public.business_region_requests for select to authenticated using(public.is_admin() or public.has_business_permission(business_id,'listing'));
revoke all on public.service_regions,public.business_service_regions,public.business_region_requests from public,anon,authenticated;
grant select on public.service_regions,public.business_service_regions to anon,authenticated;
grant select on public.business_region_requests to authenticated;
grant all on public.service_regions,public.business_service_regions,public.business_region_requests to service_role;

insert into public.service_regions(name,sort_order) values('가평',0),('대성리',1) on conflict(name) do nothing;
insert into public.business_service_regions(business_id,region_id)
select b.id,r.id from public.businesses b cross join public.service_regions r
where b.business_type='stay' and not b.service_regions_initialized and (
  (r.name='가평' and concat_ws(' ',b.region,b.address) ~ '(가평|대성리|청평)')
  or (r.name='대성리' and concat_ws(' ',b.region,b.address) like '%대성리%')
) on conflict do nothing;
update public.businesses set service_regions_initialized=true where business_type='stay' and not service_regions_initialized;

create or replace function public.list_business_service_regions()
returns table(business_id uuid,region_ids uuid[],regions text[])
language sql stable security definer set search_path='' as $$
  select b.id, coalesce(array_agg(r.id order by r.sort_order,r.name) filter(where r.id is not null),'{}'::uuid[]),
    coalesce(array_agg(r.name order by r.sort_order,r.name) filter(where r.id is not null),'{}'::text[])
  from public.businesses b
  left join public.business_service_regions br on br.business_id=b.id
  left join public.service_regions r on r.id=br.region_id and r.is_active
  where b.business_type='stay' and b.approval_status='approved' group by b.id;
$$;
create or replace function public.admin_save_service_region(target_id uuid,region_name text,region_order integer,enabled boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  if region_name is null or length(trim(region_name)) not between 1 and 30 then raise exception '지역명은 1~30자로 입력해주세요.'; end if;
  if target_id is null then
    insert into public.service_regions(name,sort_order,is_active) values(trim(region_name),coalesce(region_order,0),coalesce(enabled,true)) returning id into result;
  else
    update public.service_regions set name=trim(region_name),sort_order=coalesce(region_order,0),is_active=coalesce(enabled,true) where id=target_id returning id into result;
    if result is null then raise exception '지역을 찾을 수 없습니다.'; end if;
  end if;
  return result;
end;
$$;
create or replace function public.admin_set_business_service_regions(target_business_id uuid,selected_region_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
declare ids uuid[]; count_ids integer;
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  perform 1 from public.businesses where id=target_business_id and business_type='stay' for update;
  if not found then raise exception '숙소를 찾을 수 없습니다.'; end if;
  select coalesce(array_agg(distinct x),'{}'::uuid[]) into ids from unnest(selected_region_ids) x where x is not null;
  select count(*) into count_ids from public.service_regions where id=any(ids) and is_active;
  if cardinality(ids)>10 or count_ids<>cardinality(ids) then raise exception '사용 중인 지역을 최대 10개 선택해주세요.'; end if;
  delete from public.business_service_regions where business_id=target_business_id;
  insert into public.business_service_regions(business_id,region_id) select target_business_id,unnest(ids);
  update public.businesses set service_regions_initialized=true where id=target_business_id;
end;
$$;
create or replace function public.request_business_service_regions(target_business_id uuid,selected_region_ids uuid[],request_reason text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare ids uuid[]; result uuid;
begin
  if auth.uid() is null or not public.has_business_permission(target_business_id,'listing') then raise exception '숙소 정보를 관리할 권한이 없습니다.'; end if;
  perform 1 from public.businesses where id=target_business_id and business_type='stay' for update;
  if not found then raise exception '숙소를 찾을 수 없습니다.'; end if;
  select array_agg(distinct x) into ids from unnest(selected_region_ids) x where x is not null;
  if coalesce(cardinality(ids),0) not between 1 and 10 or (select count(*) from public.service_regions where id=any(ids) and is_active)<>cardinality(ids) then raise exception '사용 중인 지역을 1~10개 선택해주세요.'; end if;
  update public.business_region_requests set status='cancelled',reviewed_at=now() where business_id=target_business_id and status='pending';
  insert into public.business_region_requests(business_id,requested_by,region_ids,reason)
    values(target_business_id,auth.uid(),ids,left(request_reason,500)) returning id into result;
  return result;
end;
$$;
create or replace function public.review_business_service_regions(target_request_id uuid,accept_request boolean,decision_note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare request public.business_region_requests%rowtype;
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  select * into request from public.business_region_requests where id=target_request_id for update;
  if request.id is null or request.status<>'pending' then raise exception '이미 처리되었거나 존재하지 않는 신청입니다.'; end if;
  if accept_request then perform public.admin_set_business_service_regions(request.business_id,request.region_ids); end if;
  update public.business_region_requests set status=case when accept_request then 'approved' else 'rejected' end,
    reviewed_by=auth.uid(),reviewed_at=now(),review_note=left(decision_note,500) where id=request.id;
end;
$$;
revoke all on function public.list_business_service_regions() from public;
grant execute on function public.list_business_service_regions() to anon,authenticated;
revoke all on function public.admin_save_service_region(uuid,text,integer,boolean),public.admin_set_business_service_regions(uuid,uuid[]),public.request_business_service_regions(uuid,uuid[],text),public.review_business_service_regions(uuid,boolean,text) from public,anon;
grant execute on function public.admin_save_service_region(uuid,text,integer,boolean),public.admin_set_business_service_regions(uuid,uuid[]),public.request_business_service_regions(uuid,uuid[],text),public.review_business_service_regions(uuid,boolean,text) to authenticated;
commit;
