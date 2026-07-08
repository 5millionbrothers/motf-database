-- moTF 26B: PortOne KG Inicis virtual account payment intent state

alter table public.payment_intents
  drop constraint if exists payment_intents_status_check;

alter table public.payment_intents
  add constraint payment_intents_status_check
  check (status in ('prepared', 'virtual_account_issued', 'confirmed', 'failed', 'expired'));

alter table public.payment_intents
  add column if not exists portone_response jsonb,
  add column if not exists virtual_account jsonb,
  add column if not exists virtual_account_issued_at timestamptz;

drop policy if exists "payment_intents_read_partner_business" on public.payment_intents;
create policy "payment_intents_read_partner_business"
on public.payment_intents for select to authenticated
using (
  exists (
    select 1
    from public.businesses b
    where b.owner_id = auth.uid()
      and b.id = ((payment_intents.draft ->> 'business_id')::uuid)
  )
);

drop function if exists public.mark_virtual_account_issued(uuid,text,jsonb);

create or replace function public.mark_virtual_account_issued(
  target_customer_id uuid,
  target_order_id text,
  portone_response jsonb
)
returns table(order_id text, virtual_account jsonb)
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent public.payment_intents%rowtype;
  account_payload jsonb;
  provider_payment_key text;
begin
  select * into intent
  from public.payment_intents
  where payment_intents.order_id = target_order_id
  for update;

  if intent.id is null or intent.customer_id <> target_customer_id then
    raise exception '결제 대기 내역을 찾을 수 없습니다.';
  end if;

  if intent.status not in ('prepared', 'virtual_account_issued') then
    raise exception '처리할 수 없는 결제 상태입니다.';
  end if;

  account_payload := coalesce(
    portone_response -> 'virtualAccount',
    portone_response -> 'virtual_account',
    portone_response #> '{method,virtualAccount}',
    portone_response #> '{method,virtual_account}',
    '{}'::jsonb
  );
  provider_payment_key := coalesce(
    portone_response ->> 'transactionId',
    portone_response ->> 'txId',
    portone_response ->> 'id',
    target_order_id
  );

  update public.payment_intents
  set status = 'virtual_account_issued',
      payment_key = provider_payment_key,
      portone_response = mark_virtual_account_issued.portone_response,
      virtual_account = account_payload,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now())
  where id = intent.id;

  return query select target_order_id, account_payload;
end;
$$;

create or replace function public.finalize_payment_intent(
  target_customer_id uuid,
  target_order_id text,
  target_payment_key text,
  portone_response jsonb
)
returns table(transaction_id uuid, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent public.payment_intents%rowtype;
  new_transaction_id uuid;
  provider_status text;
begin
  select * into intent
  from public.payment_intents
  where order_id = target_order_id
  for update;

  if intent.id is null or intent.customer_id <> target_customer_id then
    raise exception '결제 대기 내역을 찾을 수 없습니다.';
  end if;
  if intent.status = 'confirmed' then
    return query select intent.transaction_id, intent.kind;
    return;
  end if;
  if intent.status not in ('prepared', 'virtual_account_issued') then
    raise exception '처리할 수 없는 결제 상태입니다.';
  end if;

  provider_status := coalesce(portone_response ->> 'status', portone_response ->> 'paymentStatus');
  if provider_status is distinct from 'PAID' then
    raise exception '포트원 결제 상태가 완료가 아닙니다.';
  end if;

  if intent.kind = 'stay' then
    insert into public.reservations (
      business_id, customer_id, offering_id, customer_name, group_name,
      contact_phone, event_date, guest_count, offering_name, total_amount, request_memo
    ) values (
      (intent.draft ->> 'business_id')::uuid,
      intent.customer_id,
      (intent.draft ->> 'offering_id')::uuid,
      intent.draft ->> 'customer_name',
      intent.draft ->> 'group_name',
      intent.draft ->> 'contact_phone',
      (intent.draft ->> 'event_date')::date,
      (intent.draft ->> 'guest_count')::integer,
      intent.draft ->> 'offering_name',
      intent.amount,
      intent.draft ->> 'request_memo'
    ) returning id into new_transaction_id;
  else
    insert into public.market_orders (
      business_id, customer_id, customer_name, contact_phone,
      pickup_place, pickup_time, request_memo, total_amount
    ) values (
      (intent.draft ->> 'business_id')::uuid,
      intent.customer_id,
      intent.draft ->> 'customer_name',
      intent.draft ->> 'contact_phone',
      intent.draft ->> 'pickup_place',
      (intent.draft ->> 'pickup_time')::time,
      intent.draft ->> 'request_memo',
      intent.amount
    ) returning id into new_transaction_id;

    insert into public.market_order_items (order_id, offering_id, item_name, quantity, unit_price)
    select
      new_transaction_id,
      item.offering_id,
      item.item_name,
      item.quantity,
      item.unit_price
    from jsonb_to_recordset(intent.draft -> 'items') as item(
      offering_id uuid,
      item_name text,
      quantity integer,
      unit_price integer
    );
  end if;

  update public.payment_intents
  set status = 'confirmed',
      payment_key = target_payment_key,
      transaction_id = new_transaction_id,
      portone_response = finalize_payment_intent.portone_response,
      toss_response = finalize_payment_intent.portone_response,
      confirmed_at = now()
  where id = intent.id;

  return query select new_transaction_id, intent.kind;
end;
$$;

revoke all on function public.mark_virtual_account_issued(uuid,text,jsonb) from public;
revoke all on function public.finalize_payment_intent(uuid,text,text,jsonb) from public;
grant execute on function public.mark_virtual_account_issued(uuid,text,jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid,text,text,jsonb) to service_role;
