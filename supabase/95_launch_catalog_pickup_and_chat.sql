-- Apply after 94. Additive launch changes; no payment/provider switch or financial deletion.
begin;
alter table public.offerings add column if not exists retired_at timestamptz;
alter table public.reservations add column if not exists launch_archived_at timestamptz;
alter table public.market_orders add column if not exists launch_archived_at timestamptz;
alter table public.conversations add column if not exists customer_opened_at timestamptz;
alter table public.conversations add column if not exists launch_archived_at timestamptz;
alter table public.mt_projects add column if not exists launch_archived_at timestamptz;

-- Superseded spreadsheet import only. Inactive current products are NOT retired.
update public.offerings set retired_at=now()
where business_id='d5513697-7341-4cc6-a16b-781caf6b902d' and not is_active and retired_at is null
and detail_sections->>'importSource'='google-sheet:11c1HDFn069x4ghtMJaAQZsVFa69zNTeevvOY-BwFN-I:gid-479454213';
create index if not exists current_business_offerings on public.offerings(business_id,sort_order) where retired_at is null;

create or replace function public.enforce_market_pickup_location()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_table_name='payment_intents' then
    if new.kind='market' then
      new.draft=jsonb_set(coalesce(new.draft,'{}'::jsonb),'{pickup_place}',to_jsonb('대성공판장'::text),true);
    end if;
  else
    new.pickup_place='대성공판장';
  end if;
  return new;
end;
$$;
drop trigger if exists market_checkout_fixed_pickup on public.payment_intents;
create trigger market_checkout_fixed_pickup before insert or update of draft on public.payment_intents
for each row execute function public.enforce_market_pickup_location();
drop trigger if exists market_order_fixed_pickup on public.market_orders;
create trigger market_order_fixed_pickup before insert on public.market_orders
for each row execute function public.enforce_market_pickup_location();

-- Keep existing identity, organization, and reservation checks in the original RPCs.
do $$ begin
  if to_regprocedure('public.launch_original_business_chat(uuid,uuid)') is null then
    alter function public.start_business_conversation(uuid,uuid) rename to launch_original_business_chat;
  end if;
  if to_regprocedure('public.launch_original_organization_chat(uuid,uuid,uuid)') is null then
    alter function public.start_organization_business_conversation(uuid,uuid,uuid) rename to launch_original_organization_chat;
  end if;
end $$;
revoke all on function public.launch_original_business_chat(uuid,uuid),public.launch_original_organization_chat(uuid,uuid,uuid) from public,anon,authenticated;
create or replace function public.start_business_conversation(target_business_id uuid,target_reservation_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
  result_id=public.launch_original_business_chat(target_business_id,target_reservation_id);
  update public.conversations set customer_opened_at=coalesce(customer_opened_at,now()),launch_archived_at=null where id=result_id;
  return result_id;
end;
$$;
create or replace function public.start_organization_business_conversation(target_organization_id uuid,target_business_id uuid,target_reservation_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
  result_id=public.launch_original_organization_chat(target_organization_id,target_business_id,target_reservation_id);
  update public.conversations set customer_opened_at=coalesce(customer_opened_at,now()),launch_archived_at=null where id=result_id;
  return result_id;
end;
$$;
revoke all on function public.start_business_conversation(uuid,uuid),public.start_organization_business_conversation(uuid,uuid,uuid) from public,anon;
grant execute on function public.start_business_conversation(uuid,uuid),public.start_organization_business_conversation(uuid,uuid,uuid) to authenticated;

create or replace function public.ensure_transaction_conversation(business uuid,customer uuid,organization uuid,customer_label text,group_label text,reservation uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
  if customer is null then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended(coalesce(organization,customer)::text||':'||business::text,0));
  select c.id into result_id from public.conversations c
  where c.business_id=business and c.organization_id is not distinct from organization
    and (organization is not null or c.customer_id=customer)
  order by c.created_at limit 1;
  if result_id is null then
    insert into public.conversations(business_id,customer_id,organization_id,reservation_id,customer_name,group_name)
    values(business,customer,organization,reservation,coalesce(nullif(customer_label,''),'이용자'),group_label)
    returning id into result_id;
  end if;
  return result_id;
end;
$$;
revoke all on function public.ensure_transaction_conversation(uuid,uuid,uuid,text,text,uuid) from public,anon,authenticated;
create or replace function public.create_transaction_chat()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.launch_archived_at is null then
    perform public.ensure_transaction_conversation(new.business_id,new.customer_id,new.organization_id,new.customer_name,
      to_jsonb(new)->>'group_name',case when tg_table_name='reservations' then new.id else null end);
  end if;
  return new;
end;
$$;
revoke all on function public.create_transaction_chat() from public,anon,authenticated;
drop trigger if exists reservation_start_chat on public.reservations;
create trigger reservation_start_chat after insert on public.reservations for each row execute function public.create_transaction_chat();
drop trigger if exists market_order_start_chat on public.market_orders;
create trigger market_order_start_chat after insert on public.market_orders for each row execute function public.create_transaction_chat();
select public.ensure_transaction_conversation(r.business_id,r.customer_id,r.organization_id,r.customer_name,r.group_name,r.id)
from public.reservations r where r.launch_archived_at is null and r.customer_id is not null;
select public.ensure_transaction_conversation(o.business_id,o.customer_id,o.organization_id,o.customer_name,null,null)
from public.market_orders o where o.launch_archived_at is null and o.customer_id is not null;

create or replace function public.list_relevant_conversation_ids(target_business_id uuid default null,target_organization_id uuid default null)
returns table(id uuid) language sql stable security definer set search_path='' as $$
  select c.id from public.conversations c join public.businesses b on b.id=c.business_id
  where public.can_access_conversation(c.id) and c.launch_archived_at is null
    and (case when target_business_id is not null then c.business_id=target_business_id
      else c.organization_id is not distinct from target_organization_id end)
    and (b.business_type='support' and b.is_internal or c.customer_opened_at is not null
      or exists(select 1 from public.messages m where m.conversation_id=c.id)
      or exists(select 1 from public.reservations r where r.business_id=c.business_id and r.launch_archived_at is null
        and r.organization_id is not distinct from c.organization_id and (c.organization_id is not null or r.customer_id=c.customer_id))
      or exists(select 1 from public.market_orders o where o.business_id=c.business_id and o.launch_archived_at is null
        and o.organization_id is not distinct from c.organization_id and (c.organization_id is not null or o.customer_id=c.customer_id)));
$$;
revoke all on function public.list_relevant_conversation_ids(uuid,uuid) from public,anon;
grant execute on function public.list_relevant_conversation_ids(uuid,uuid) to authenticated;

create or replace function public.reorder_business_products(target_business_id uuid,ordered_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
declare actual_count integer;
begin
  if not coalesce(public.is_admin() or public.has_business_permission(target_business_id,'listing'),false) then
    raise exception '상품을 관리할 권한이 없습니다.'; end if;
  perform 1 from public.businesses where id=target_business_id and business_type='market' for update;
  if not found then raise exception '장보기 업장을 찾을 수 없습니다.'; end if;
  if ordered_ids is null or array_position(ordered_ids,null) is not null
    or cardinality(ordered_ids)<>(select count(distinct value) from unnest(ordered_ids) value) then
    raise exception '상품 목록에 중복 또는 빈 항목이 있습니다.'; end if;
  select count(*) into actual_count from public.offerings where business_id=target_business_id and retired_at is null;
  if actual_count<>cardinality(ordered_ids) or actual_count<>(select count(*) from public.offerings where business_id=target_business_id and retired_at is null and id=any(ordered_ids)) then
    raise exception '상품 목록이 변경되었습니다. 미리보기를 다시 열어주세요.'; end if;
  update public.offerings o set sort_order=(x.position-1)::integer
  from unnest(ordered_ids) with ordinality x(id,position)
  where o.id=x.id and o.business_id=target_business_id and o.retired_at is null;
end;
$$;
revoke all on function public.reorder_business_products(uuid,uuid[]) from public,anon;
grant execute on function public.reorder_business_products(uuid,uuid[]) to authenticated;

insert into public.service_regions(name,sort_order,is_active) values('가평',0,true),('대성리',1,true)
on conflict(name) do update set is_active=true;
insert into public.business_service_regions(business_id,region_id)
select b.id,r.id from public.businesses b cross join public.service_regions r
where b.business_type='stay' and r.name in ('가평','대성리') on conflict do nothing;
update public.businesses set service_regions_initialized=true where business_type='stay' and not service_regions_initialized;
notify pgrst,'reload schema';
commit;
