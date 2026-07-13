-- PortOne payment hardening.
-- Makes amount parsing safer across PortOne response shapes and adds a transaction id guard.

create unique index if not exists payment_intents_transaction_unique_idx
on public.payment_intents(transaction_id)
where transaction_id is not null;

drop function if exists public.finalize_payment_intent(uuid, text, text, jsonb);

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
    case
      when jsonb_typeof(portone_response -> 'amount') = 'object'
      then nullif(portone_response #>> '{amount,total}', '')::integer
      else null
    end,
    case
      when jsonb_typeof(portone_response -> 'amount') = 'number'
      then nullif(portone_response ->> 'amount', '')::integer
      else null
    end,
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

revoke all on function public.finalize_payment_intent(uuid, text, text, jsonb) from public;
grant execute on function public.finalize_payment_intent(uuid, text, text, jsonb) to service_role;
