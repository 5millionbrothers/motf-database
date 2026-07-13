-- PortOne KG Inicis virtual-account payment foundation.
-- Virtual-account issuance is not a paid transaction. Reservations/orders are created only after PAID.

alter table public.payment_intents
  drop constraint if exists payment_intents_status_check;

alter table public.payment_intents
  add constraint payment_intents_status_check
  check (status in ('prepared', 'virtual_account_issued', 'confirmed', 'failed', 'expired'));

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'payment_intents'
      and column_name = 'toss_response'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'payment_intents'
      and column_name = 'payment_response'
  ) then
    alter table public.payment_intents rename column toss_response to payment_response;
  end if;
end $$;

alter table public.payment_intents
  add column if not exists payment_response jsonb;

alter table public.payment_intents
  add column if not exists provider text not null default 'portone',
  add column if not exists pg_provider text,
  add column if not exists channel_key text,
  add column if not exists virtual_account jsonb,
  add column if not exists virtual_account_issued_at timestamptz,
  add column if not exists paid_at timestamptz;

drop function if exists public.mark_virtual_account_issued(uuid, text, jsonb);
drop function if exists public.finalize_payment_intent(uuid, text, text, jsonb);

create or replace function public.mark_virtual_account_issued(
  target_customer_id uuid,
  target_order_id text,
  portone_response jsonb
)
returns table(order_id text, status text, virtual_account jsonb)
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent public.payment_intents%rowtype;
begin
  select * into intent
  from public.payment_intents
  where payment_intents.order_id = target_order_id
  for update;

  if intent.id is null or intent.customer_id <> target_customer_id then
    raise exception 'Payment intent not found.';
  end if;
  if intent.status = 'confirmed' then
    return query select intent.order_id, intent.status, intent.virtual_account;
    return;
  end if;
  if intent.status not in ('prepared', 'virtual_account_issued') then
    raise exception 'Payment intent cannot be marked as virtual-account issued.';
  end if;

  update public.payment_intents
  set status = 'virtual_account_issued',
      provider = 'portone',
      pg_provider = coalesce(portone_response ->> 'pgProvider', portone_response ->> 'pg_provider', pg_provider),
      channel_key = coalesce(portone_response ->> 'channelKey', portone_response ->> 'channel_key', channel_key),
      virtual_account = coalesce(portone_response -> 'virtualAccount', portone_response -> 'virtual_account', portone_response -> 'virtualAccountIssued'),
      payment_response = portone_response,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now())
  where id = intent.id
  returning payment_intents.order_id, payment_intents.status, payment_intents.virtual_account
  into order_id, status, virtual_account;

  return next;
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
  response_status text;
  response_amount integer;
begin
  select * into intent
  from public.payment_intents
  where order_id = target_order_id
  for update;

  if intent.id is null or intent.customer_id <> target_customer_id then
    raise exception 'Payment intent not found.';
  end if;
  if intent.status = 'confirmed' then
    return query select intent.transaction_id, intent.kind;
    return;
  end if;
  if intent.status not in ('prepared', 'virtual_account_issued') then
    raise exception 'Payment intent cannot be finalized.';
  end if;

  response_status := coalesce(portone_response ->> 'status', portone_response ->> 'paymentStatus');
  response_amount := coalesce(
    nullif(portone_response #>> '{amount,total}', '')::integer,
    nullif(portone_response ->> 'amount', '')::integer,
    nullif(portone_response ->> 'totalAmount', '')::integer,
    -1
  );

  if coalesce(portone_response ->> 'id', portone_response ->> 'paymentId', portone_response ->> 'orderId') is distinct from intent.order_id
     or response_amount <> intent.amount
     or response_status <> 'PAID' then
    raise exception 'PortOne payment does not match the prepared intent.';
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
      provider = 'portone',
      payment_response = portone_response,
      paid_at = now(),
      confirmed_at = now()
  where id = intent.id;

  return query select new_transaction_id, intent.kind;
end;
$$;

revoke all on function public.mark_virtual_account_issued(uuid, text, jsonb) from public;
revoke all on function public.finalize_payment_intent(uuid, text, text, jsonb) from public;
grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid, text, text, jsonb) to service_role;
