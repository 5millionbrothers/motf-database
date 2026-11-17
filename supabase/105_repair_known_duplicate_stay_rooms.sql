-- Only Mozart Chalet and Byeoljji. Retire duplicates; never delete transaction history.
begin;
create table if not exists public.stay_room_repair_archive (
  record_kind text not null check(record_kind in ('offering','listing_review')),
  record_id uuid not null, business_id uuid not null, kept_offering_id uuid,
  snapshot jsonb not null, archived_at timestamptz not null default now(),
  primary key(record_kind,record_id)
);
alter table public.stay_room_repair_archive enable row level security;
revoke all on public.stay_room_repair_archive from public,anon,authenticated;
grant select on public.stay_room_repair_archive to service_role;

-- Serialize with saves and approvals. Exact IDs avoid changing unrelated stays.
do $$ begin
  perform 1 from public.business_listing_review_requests r where r.status='pending' and r.business_id in
    ('50e5c710-3310-4eaa-8f09-9f7c768ff066','7390b68e-d374-4eb4-8e9d-d15034f827dc') order by r.id for update;
  perform 1 from public.businesses b where b.business_type='stay' and b.id in
    ('50e5c710-3310-4eaa-8f09-9f7c768ff066','7390b68e-d374-4eb4-8e9d-d15034f827dc') order by b.id for update;
  -- Checkout locks the room too: no new payment can start while it is retired.
  perform 1 from public.offerings o where o.business_id in
    ('50e5c710-3310-4eaa-8f09-9f7c768ff066','7390b68e-d374-4eb4-8e9d-d15034f827dc') order by o.id for update;
end $$;

create temporary table repaired_room_map on commit drop as
with live_rooms as (
  select offering_id from public.stay_availability_blocks where status='active' and end_date>current_date
  union select offering_id from public.reservations where launch_archived_at is null
    and status not in ('cancelled','rejected','completed') and coalesce(end_date,event_date)>=current_date
  union select nullif(draft->>'offering_id','')::uuid from public.payment_intents
    where kind='stay' and status in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit','awaiting_deposit') and expires_at>now()
), ranked as (
  select o.id,o.business_id,lower(trim(o.name)) room_key,
    first_value(o.id) over(partition by o.business_id,lower(trim(o.name))
      order by exists(select 1 from live_rooms l where l.offering_id=o.id) desc,
        o.is_active desc,o.updated_at desc,o.created_at,o.id) kept_id,
    count(*) over(partition by o.business_id,lower(trim(o.name))) copies
  from public.offerings o join public.businesses b on b.id=o.business_id
  where b.business_type='stay' and o.retired_at is null and trim(o.name)<>''
    and ((b.id='50e5c710-3310-4eaa-8f09-9f7c768ff066' and b.business_name='모짜르트 샬레')
      or (b.id='7390b68e-d374-4eb4-8e9d-d15034f827dc' and b.business_name='별찌 펜션'))
)
select * from ranked where copies>1;

-- Never remove a separately booked room or a room with a live checkout/block.
do $$ begin
  if exists(select 1 from repaired_room_map m where m.id<>m.kept_id and (
    exists(select 1 from public.stay_availability_blocks b where b.offering_id=m.id and b.status='active' and b.end_date>current_date)
    or exists(select 1 from public.reservations r where r.offering_id=m.id and r.launch_archived_at is null
      and r.status not in ('cancelled','rejected','completed') and coalesce(r.end_date,r.event_date)>=current_date)
    or exists(select 1 from public.payment_intents p where p.kind='stay' and p.draft->>'offering_id'=m.id::text
      and p.status in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit','awaiting_deposit') and p.expires_at>now())
  )) then raise exception '중복 객실 여러 개에 진행 중인 예약·결제·방막기가 있습니다. 해당 내역 확인 후 객실을 정리해주세요. 데이터는 변경하지 않았습니다.'; end if;
  -- The confirmed Mozart copies differed only in pictures. Stop if that has changed.
  if exists(select 1 from repaired_room_map m join public.offerings o on o.id=m.id join public.offerings k on k.id=m.kept_id
    where m.business_id='50e5c710-3310-4eaa-8f09-9f7c768ff066'
    and (to_jsonb(o)-array['id','sort_order','created_at','updated_at','image_url','image_urls','is_active'])
      is distinct from (to_jsonb(k)-array['id','sort_order','created_at','updated_at','image_url','image_urls','is_active']))
    then raise exception '모짜르트 중복 객실의 요금·인원·설명이 서로 다릅니다. 실제로 다른 객실인지 확인해주세요. 데이터는 변경하지 않았습니다.'; end if;
end $$;

insert into public.stay_room_repair_archive(record_kind,record_id,business_id,kept_offering_id,snapshot)
select 'offering',o.id,o.business_id,m.kept_id,to_jsonb(o) from public.offerings o join repaired_room_map m on m.id=o.id
on conflict(record_kind,record_id) do nothing;

-- Keep the chosen cover first, and retain unique pictures from every duplicate.
with pictures as (
  select m.kept_id,u.url,min(case when m.id=m.kept_id then 0 else 1 end) preferred,
    min(o.sort_order) room_order,min(u.position) photo_order
  from repaired_room_map m join public.offerings o on o.id=m.id
  cross join lateral unnest(array_prepend(o.image_url,coalesce(o.image_urls,'{}'))) with ordinality u(url,position)
  where nullif(trim(u.url),'') is not null group by m.kept_id,u.url
), merged as (
  select kept_id,array_agg(url order by preferred,room_order,photo_order,url) urls from pictures group by kept_id
)
update public.offerings o set image_urls=x.urls,image_url=x.urls[1],updated_at=now()
from merged x where o.id=x.kept_id and (o.image_urls is distinct from x.urls or o.image_url is distinct from x.urls[1]);
update public.offerings o set is_active=false,retired_at=now(),updated_at=now()
from repaired_room_map m where o.id=m.id and m.id<>m.kept_id;

-- Normalize unapproved drafts too, otherwise approving an old draft restores copies.
create function pg_temp.repair_pending_room_ids(items jsonb,business uuid) returns jsonb
language sql stable as $$
  with resolved as (
    select p.position,p.item,coalesce(
      (select a.kept_offering_id from public.stay_room_repair_archive a where a.record_kind='offering' and a.business_id=business and a.record_id::text=p.item->>'id'),
      (select o.id from public.offerings o where o.business_id=business and o.retired_at is null and lower(trim(o.name))=lower(trim(p.item->>'name')) order by o.is_active desc,o.updated_at desc,o.id limit 1)
    ) kept_id from jsonb_array_elements(items) with ordinality p(item,position)
  ), chosen as (
    select distinct on (coalesce(kept_id::text,lower(trim(item->>'name')))) position,
      case when kept_id is null then item else jsonb_set(item,'{id}',to_jsonb(kept_id::text)) end item
    from resolved order by coalesce(kept_id::text,lower(trim(item->>'name'))),
      (item->>'id'=kept_id::text) desc nulls last,position desc
  ) select coalesce(jsonb_agg(item order by position),'[]') from chosen;
$$;
insert into public.stay_room_repair_archive(record_kind,record_id,business_id,snapshot)
select 'listing_review',r.id,r.business_id,to_jsonb(r) from public.business_listing_review_requests r
where r.status='pending' and exists(select 1 from repaired_room_map m where m.business_id=r.business_id)
  and r.proposed_offerings is distinct from pg_temp.repair_pending_room_ids(r.proposed_offerings,r.business_id)
on conflict(record_kind,record_id) do nothing;
update public.business_listing_review_requests r set proposed_offerings=pg_temp.repair_pending_room_ids(r.proposed_offerings,r.business_id),updated_at=now()
where r.status='pending' and exists(select 1 from repaired_room_map m where m.business_id=r.business_id)
  and r.proposed_offerings is distinct from pg_temp.repair_pending_room_ids(r.proposed_offerings,r.business_id);
drop function pg_temp.repair_pending_room_ids(jsonb,uuid);

update public.businesses b set room_count=(select count(*) from public.offerings o where o.business_id=b.id and o.retired_at is null and o.is_active),updated_at=now()
where exists(select 1 from repaired_room_map m where m.business_id=b.id);
do $$ declare business uuid; begin
  for business in select distinct business_id from repaired_room_map loop perform public.refresh_business_highlights(business); end loop;
end $$;
commit;
