begin;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('settlement-receipts','settlement-receipts',false,2097152,array['application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.can_manage_settlement_receipt(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
  select public.is_admin() and exists (
    select 1 from public.payment_intents pi
    where pi.id = case when object_name ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/(card|cash)\.pdf$'
                       then split_part(object_name,'/',1)::uuid end
      and pi.provider in ('nicepay','toss') and pi.paid_at is not null and pi.amount>0
      and pi.status in ('confirmed','cancelled','partial_cancelled')
      and ((pi.kind='stay' and exists(select 1 from public.reservations r where r.id=pi.transaction_id and r.launch_archived_at is null))
        or (pi.kind='market' and exists(select 1 from public.market_orders m where m.id=pi.transaction_id and m.launch_archived_at is null)))
  );
$$;
revoke all on function public.can_manage_settlement_receipt(text) from public,anon;
grant execute on function public.can_manage_settlement_receipt(text) to authenticated;

drop policy if exists settlement_receipts_admin on storage.objects;
create policy settlement_receipts_admin on storage.objects for all to authenticated
  using (bucket_id='settlement-receipts' and public.can_manage_settlement_receipt(name))
  with check (bucket_id='settlement-receipts' and public.can_manage_settlement_receipt(name));
-- Cover future broad Storage policies too: this bucket must never be public to customers.
drop policy if exists settlement_receipts_private on storage.objects;
create policy settlement_receipts_private on storage.objects as restrictive for all to authenticated
  using (bucket_id<>'settlement-receipts' or public.can_manage_settlement_receipt(name))
  with check (bucket_id<>'settlement-receipts' or public.can_manage_settlement_receipt(name));
drop policy if exists settlement_receipts_no_anon on storage.objects;
create policy settlement_receipts_no_anon on storage.objects as restrictive for all to anon
  using (bucket_id<>'settlement-receipts') with check (bucket_id<>'settlement-receipts');

create or replace function public.get_admin_settlement_receipt_target(target_kind text,target_transaction_id uuid)
returns table(intent_id uuid,order_id text,payment_method text,amount integer,receipt_kinds text[])
language sql stable security definer set search_path='' as $$
  select pi.id,pi.order_id,pi.payment_method,pi.amount,
    array(select split_part(split_part(o.name,'/',2),'.',1) from storage.objects o
      where o.bucket_id='settlement-receipts' and o.name in (pi.id::text||'/card.pdf',pi.id::text||'/cash.pdf') order by o.name)
  from public.payment_intents pi
  where pi.kind=target_kind and pi.transaction_id=target_transaction_id
    and public.can_manage_settlement_receipt(pi.id::text||'/card.pdf')
  order by pi.created_at desc,pi.id desc limit 1;
$$;
revoke all on function public.get_admin_settlement_receipt_target(text,uuid) from public,anon;
grant execute on function public.get_admin_settlement_receipt_target(text,uuid) to authenticated;

-- The customer API passes only intent IDs it resolved from scoped, paid orders.
create or replace function public.list_settlement_receipt_attachments(target_intent_ids uuid[])
returns table(intent_id uuid,object_path text) language sql stable security definer set search_path='' as $$
  select ids.id,o.name
  from (select distinct unnest(target_intent_ids) as id) ids
  join storage.objects o on o.bucket_id='settlement-receipts'
    and o.name in (ids.id::text||'/card.pdf',ids.id::text||'/cash.pdf');
$$;
revoke all on function public.list_settlement_receipt_attachments(uuid[]) from public,anon,authenticated;
grant execute on function public.list_settlement_receipt_attachments(uuid[]) to service_role;

notify pgrst,'reload schema';
commit;
