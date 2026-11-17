-- Isolated demonstrations: never enter payments, inventory, notifications or revenue.
begin;
create table if not exists public.reservation_demos (
  id uuid primary key default gen_random_uuid(),request_key uuid not null,
  business_id uuid not null references public.businesses(id),offering_id uuid not null references public.offerings(id),
  created_by uuid not null references public.profiles(id),customer_name text not null,contact_phone text not null,
  check_in date not null,check_out date not null,guest_count integer not null check(guest_count between 1 and 500),
  offering_name text not null,total_amount integer not null check(total_amount between 0 and 10000000),request_memo text,
  status text not null default 'pending' check(status in ('pending','confirmed','rejected')),
  reject_reason text,handled_by uuid references public.profiles(id),handled_at timestamptz,
  created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '7 days',archived_at timestamptz,
  unique(request_key,business_id),check(check_out>check_in)
);
create index if not exists reservation_demos_business on public.reservation_demos(business_id,created_at desc) where archived_at is null;
alter table public.reservation_demos enable row level security;
revoke all on public.reservation_demos from public,anon,authenticated;
grant select on public.reservation_demos to authenticated;
drop policy if exists reservation_demos_read on public.reservation_demos;
create policy reservation_demos_read on public.reservation_demos for select to authenticated
using(public.is_admin() or (archived_at is null and expires_at>now() and public.has_business_permission(business_id,'reservations')));

create or replace function public.create_admin_reservation_demo(
  target_business_ids uuid[],target_offering_id uuid,demo_check_in date,demo_check_out date,
  demo_guests integer,demo_customer text,demo_phone text,demo_memo text,submission_key uuid
) returns setof public.reservation_demos language plpgsql security definer set search_path='' as $$
declare bid uuid;room public.offerings%rowtype;row public.reservation_demos%rowtype;
begin
  if not coalesce(public.is_admin(),false) then raise exception '운영자만 테스트 예약을 만들 수 있습니다.' using errcode='42501'; end if;
  if submission_key is null or target_business_ids is null or cardinality(target_business_ids) not between 1 and 30
    or array_position(target_business_ids,null) is not null
    or demo_check_in is null or demo_check_out is null or demo_check_out<=demo_check_in
    or demo_check_out-demo_check_in>30 or demo_guests is null or demo_guests not between 1 and 500
    or length(trim(coalesce(demo_customer,''))) not between 1 and 80
    or length(regexp_replace(coalesce(demo_phone,''),'[^0-9]','','g')) not between 9 and 15
    or length(coalesce(demo_memo,''))>1000 then raise exception '숙소·일정·인원·테스트 예약자 정보를 확인해주세요.'; end if;
  if target_offering_id is not null and cardinality(target_business_ids)<>1 then raise exception '객실 지정은 숙소 한 곳에서만 가능합니다.'; end if;
  foreach bid in array target_business_ids loop
    perform 1 from public.businesses b where b.id=bid and b.business_type='stay' and b.approval_status='approved';
    if not found then raise exception '공개 중인 숙소만 테스트할 수 있습니다.'; end if;
    select * into room from public.offerings o where o.business_id=bid and o.is_active and o.retired_at is null
      and (target_offering_id is null or o.id=target_offering_id)
      order by (coalesce(o.max_people,500)>=demo_guests) desc,o.sort_order,o.id limit 1;
    if room.id is null then raise exception '테스트할 판매 중인 객실을 찾지 못했습니다.'; end if;
    insert into public.reservation_demos(request_key,business_id,offering_id,created_by,customer_name,contact_phone,
      check_in,check_out,guest_count,offering_name,total_amount,request_memo)
    values(submission_key,bid,room.id,auth.uid(),trim(demo_customer),regexp_replace(demo_phone,'[^0-9]','','g'),
      demo_check_in,demo_check_out,demo_guests,room.name,least(10000000,coalesce(room.price,0)::bigint*(demo_check_out-demo_check_in)),nullif(trim(demo_memo),''))
    on conflict(request_key,business_id) do nothing;
    select * into row from public.reservation_demos d where d.request_key=submission_key and d.business_id=bid;
    return next row;
  end loop;
end;
$$;
create or replace function public.handle_reservation_demo(target_demo_id uuid,decision text,reason text default null)
returns void language plpgsql security definer set search_path='' as $$
declare row public.reservation_demos%rowtype;
begin
  select * into row from public.reservation_demos d where d.id=target_demo_id and d.archived_at is null and d.expires_at>now() for update;
  if row.id is null then raise exception '유효한 테스트 예약을 찾지 못했습니다.'; end if;
  if not coalesce(public.is_admin() or public.has_business_permission(row.business_id,'reservations'),false) then raise exception '예약 관리 권한이 필요합니다.' using errcode='42501'; end if;
  if row.status<>'pending' or decision is null or decision not in ('confirmed','rejected') then raise exception '대기 중인 테스트 예약만 승인·거절할 수 있습니다.'; end if;
  if decision='rejected' and length(trim(coalesce(reason,''))) not between 1 and 500 then raise exception '거절 사유를 입력해주세요.'; end if;
  update public.reservation_demos set status=decision,reject_reason=case when decision='rejected' then trim(reason) else null end,handled_by=auth.uid(),handled_at=now() where id=row.id;
end;
$$;
create or replace function public.archive_reservation_demos(target_business_id uuid default null)
returns integer language plpgsql security definer set search_path='' as $$
declare changed integer;
begin
  if not coalesce(public.is_admin(),false) then raise exception '운영자만 테스트 예약을 정리할 수 있습니다.' using errcode='42501'; end if;
  update public.reservation_demos set archived_at=now() where archived_at is null and (target_business_id is null or business_id=target_business_id);
  get diagnostics changed=row_count;return changed;
end;
$$;
revoke all on function public.create_admin_reservation_demo(uuid[],uuid,date,date,integer,text,text,text,uuid),public.handle_reservation_demo(uuid,text,text),public.archive_reservation_demos(uuid) from public,anon;
grant execute on function public.create_admin_reservation_demo(uuid[],uuid,date,date,integer,text,text,text,uuid),public.handle_reservation_demo(uuid,text,text),public.archive_reservation_demos(uuid) to authenticated;
commit;
