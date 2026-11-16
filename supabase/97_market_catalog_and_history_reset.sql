-- Apply after 96. Installs reset tools; history is reset only by 98.
begin;
alter table public.payment_intents add column if not exists launch_archived_at timestamptz;
alter table public.partner_settlements add column if not exists launch_archived_at timestamptz;
alter table public.conversations add column if not exists history_started_at timestamptz;
alter table public.conversations alter column history_started_at set default now();
create table if not exists public.launch_reset_runs (
  run_key text primary key, reset_at timestamptz not null, result jsonb not null default '{}'
);
create table if not exists public.launch_reset_backups (
  run_key text not null, table_name text not null, row_id uuid not null,
  snapshot jsonb not null, primary key(run_key,table_name,row_id)
);
alter table public.launch_reset_runs enable row level security;
alter table public.launch_reset_backups enable row level security;
revoke all on public.launch_reset_runs,public.launch_reset_backups from public,anon,authenticated;
grant select on public.launch_reset_runs,public.launch_reset_backups to service_role;

-- Select the cheapest frozen pork option without changing the group's display order.
with candidates as (
  select o.id,row_number() over(partition by coalesce(nullif(o.detail_sections->>'productGroupKey',''),nullif(o.detail_sections->>'productDisplayName',''),o.name)
    order by case when concat_ws(' ',o.name,o.detail_sections->>'temperature',o.detail_sections->>'variantLabel') like '%냉동%' then 0 else 1 end,o.price,o.sort_order,o.id) as position
  from public.offerings o where o.business_id='d5513697-7341-4cc6-a16b-781caf6b902d'
    and o.is_active and o.retired_at is null and coalesce(o.detail_sections->>'productDisplayName',o.name) ~ '(삼겹|목살)'
)
update public.offerings o set detail_sections=jsonb_set(coalesce(o.detail_sections,'{}'),'{isDefaultVariant}',to_jsonb(c.position=1),true)
from candidates c where o.id=c.id;

create or replace function public.keep_retired_offering_hidden()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.retired_at is not null then new.retired_at=old.retired_at; new.is_active=false; end if;
  return new;
end;
$$;
drop trigger if exists keep_retired_offering_hidden on public.offerings;
create trigger keep_retired_offering_hidden before update on public.offerings for each row execute function public.keep_retired_offering_hidden();

create or replace function public.launch_transaction_visible(kind text,target_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.reservations r where kind='stay' and r.id=target_id and r.launch_archived_at is not null)
 and not exists(select 1 from public.market_orders o where kind='market' and o.id=target_id and o.launch_archived_at is not null)
 and not exists(select 1 from public.reservation_extra_charge_requests e join public.reservations r on r.id=e.reservation_id
   where kind='extra_charge' and e.id=target_id and r.launch_archived_at is not null);
$$;
revoke all on function public.launch_transaction_visible(text,uuid) from public,anon,authenticated;

-- Operating views are separate from the original financial/audit RPCs.
create or replace function public.list_launch_partner_settlements()
returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from public.list_own_partner_settlements() s
 where public.launch_transaction_visible(s.transaction_kind,s.transaction_id)
 and exists(select 1 from public.partner_settlements p where p.id=s.id and p.launch_archived_at is null);
$$;
create or replace function public.list_launch_admin_settlements()
returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from public.list_partner_settlements() s
 where public.launch_transaction_visible(s.transaction_kind,s.transaction_id)
 and exists(select 1 from public.partner_settlements p where p.id=s.id and p.launch_archived_at is null);
$$;
create or replace function public.list_launch_pending_payment_intents(target_business_id uuid default null)
returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) from public.list_pending_payment_intents(target_business_id) p
 where exists(select 1 from public.payment_intents i where i.order_id=p.order_id and i.launch_archived_at is null);
$$;
revoke all on function public.list_launch_partner_settlements(),public.list_launch_admin_settlements(),public.list_launch_pending_payment_intents(uuid) from public,anon;
grant execute on function public.list_launch_partner_settlements(),public.list_launch_admin_settlements(),public.list_launch_pending_payment_intents(uuid) to authenticated;

create or replace function public.ensure_transaction_conversation(business uuid,customer uuid,organization uuid,customer_label text,group_label text,reservation uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
 if customer is null then return null; end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(organization,customer)::text||':'||business::text,0));
 select c.id into result_id from public.conversations c where c.business_id=business
   and c.organization_id is not distinct from organization and (organization is not null or c.customer_id=customer)
 order by c.created_at limit 1;
 if result_id is null then
   insert into public.conversations(business_id,customer_id,organization_id,reservation_id,customer_name,group_name)
   values(business,customer,organization,reservation,coalesce(nullif(customer_label,''),'이용자'),group_label) returning id into result_id;
 else
   update public.conversations set launch_archived_at=null,reservation_id=coalesce(reservation,reservation_id),
     customer_name=coalesce(nullif(customer_label,''),customer_name),group_name=coalesce(group_label,group_name),last_message_at=now()
   where id=result_id and launch_archived_at is not null;
 end if;
 return result_id;
end;
$$;
revoke all on function public.ensure_transaction_conversation(uuid,uuid,uuid,text,text,uuid) from public,anon,authenticated;

create or replace function public.start_business_conversation(target_business_id uuid,target_reservation_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
 result_id=public.launch_original_business_chat(target_business_id,target_reservation_id);
 update public.conversations set customer_opened_at=coalesce(customer_opened_at,now()),launch_archived_at=null where id=result_id;
 return result_id;
end;
$$;
-- Keep support pinned after reset, without returning the old message history.
do $$ begin
 if to_regprocedure('public.launch_original_support_chat()') is null then
   alter function public.start_support_conversation() rename to launch_original_support_chat;
 end if;
end $$;
revoke all on function public.launch_original_support_chat() from public,anon,authenticated;
create or replace function public.start_support_conversation()
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid;
begin
 result_id=public.launch_original_support_chat();
 update public.conversations set launch_archived_at=null where id=result_id;
 return result_id;
end;
$$;
revoke all on function public.start_support_conversation() from public,anon;
grant execute on function public.start_support_conversation() to authenticated;

create or replace function public.reopen_conversation_after_reset()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.conversations set launch_archived_at=null,last_message_at=new.created_at
 where id=new.conversation_id and launch_archived_at is not null
   and new.created_at>=coalesce(history_started_at,'-infinity'::timestamptz);
 return new;
end;
$$;
drop trigger if exists reopen_conversation_after_reset on public.messages;
create trigger reopen_conversation_after_reset after insert on public.messages for each row execute function public.reopen_conversation_after_reset();
create or replace function public.reopen_new_payment_transaction()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.transaction_id is not null and new.transaction_id is distinct from old.transaction_id
   and public.launch_transaction_visible(new.kind,new.transaction_id) then new.launch_archived_at=null; end if;
 return new;
end;
$$;
drop trigger if exists reopen_new_payment_transaction on public.payment_intents;
create trigger reopen_new_payment_transaction before update of transaction_id on public.payment_intents for each row execute function public.reopen_new_payment_transaction();
revoke all on function public.reopen_conversation_after_reset(),public.reopen_new_payment_transaction() from public,anon,authenticated;

create or replace function public.list_relevant_conversation_ids(target_business_id uuid default null,target_organization_id uuid default null)
returns table(id uuid) language sql stable security definer set search_path='' as $$
 select c.id from public.conversations c join public.businesses b on b.id=c.business_id
 where public.can_access_conversation(c.id) and c.launch_archived_at is null
 and case when target_business_id is not null then c.business_id=target_business_id else c.organization_id is not distinct from target_organization_id end
 and (b.business_type='support' and b.is_internal or c.customer_opened_at is not null
   or exists(select 1 from public.messages m where m.conversation_id=c.id and m.created_at>=coalesce(c.history_started_at,'-infinity'::timestamptz))
   or exists(select 1 from public.reservations r where r.business_id=c.business_id and r.launch_archived_at is null and r.organization_id is not distinct from c.organization_id and (c.organization_id is not null or r.customer_id=c.customer_id))
   or exists(select 1 from public.market_orders o where o.business_id=c.business_id and o.launch_archived_at is null and o.organization_id is not distinct from c.organization_id and (c.organization_id is not null or o.customer_id=c.customer_id)));
$$;

-- Preview helper; only SQL Editor/service_role can execute reset tools.
create or replace function public.preview_launch_operational_reset()
returns jsonb language sql security definer set search_path='' as $$
 select jsonb_build_object(
   'reset_already_applied',exists(select 1 from public.launch_reset_runs where run_key='launch-reset-20261116'),
   'inactive_daesung_products',(select count(*) from public.offerings where business_id='d5513697-7341-4cc6-a16b-781caf6b902d' and not is_active),
   'reservations',(select count(*) from public.reservations where launch_archived_at is null),
   'market_orders',(select count(*) from public.market_orders where launch_archived_at is null),
   'conversations',(select count(*) from public.conversations where launch_archived_at is null),
   'settlements',(select count(*) from public.partner_settlements where launch_archived_at is null),
   'payment_intents',(select count(*) from public.payment_intents where launch_archived_at is null)
 );
$$;
revoke all on function public.preview_launch_operational_reset() from public,anon,authenticated;
grant execute on function public.preview_launch_operational_reset() to service_role;
notify pgrst,'reload schema';
commit;
