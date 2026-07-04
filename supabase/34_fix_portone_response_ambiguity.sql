-- Fix "column reference portone_response is ambiguous" in PortOne RPCs.
-- Keep the public RPC argument names unchanged for existing API calls, but
-- copy positional arguments into local variables before using them in SQL.

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
  stay_check_in date;
  stay_check_out date;
  stored_virtual_account jsonb;
  payment_payload jsonb := $3;
begin
  perform public.release_expired_pending_stay_blocks();

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

  stored_virtual_account := coalesce(
    payment_payload -> 'virtualAccount',
    payment_payload -> 'virtual_account',
    payment_payload -> 'virtualAccountIssued',
    payment_payload -> 'virtual_account_issued',
    payment_payload -> 'paymentMethod',
    payment_payload -> 'payment_method',
    payment_payload -> 'paymentMethodDetail',
    payment_payload -> 'payment_method_detail',
    '{}'::jsonb
  );

  if intent.kind = 'stay' then
    stay_check_in := coalesce((intent.draft ->> 'check_in_date')::date, (intent.draft ->> 'event_date')::date);
    stay_check_out := coalesce((intent.draft ->> 'check_out_date')::date, stay_check_in + 1);

    if not exists (
      select 1
      from public.stay_availability_blocks b
      where b.payment_intent_id = intent.id
        and b.status = 'active'
    ) then
      if not public.stay_range_is_available((intent.draft ->> 'offering_id')::uuid, stay_check_in, stay_check_out) then
        raise exception 'This room is already blocked for the selected dates.';
      end if;

      insert into public.stay_availability_blocks (
        business_id, offering_id, start_date, end_date, source,
        payment_intent_id, payment_order_id, note
      ) values (
        (intent.draft ->> 'business_id')::uuid,
        (intent.draft ->> 'offering_id')::uuid,
        stay_check_in,
        stay_check_out,
        'pending_payment',
        intent.id,
        intent.order_id,
        'PortOne virtual account issued'
      );
    end if;
  end if;

  update public.payment_intents
  set status = 'virtual_account_issued',
      provider = 'portone',
      pg_provider = coalesce(payment_payload ->> 'pgProvider', payment_payload ->> 'pg_provider', pg_provider),
      channel_key = coalesce(payment_payload ->> 'channelKey', payment_payload ->> 'channel_key', channel_key),
      virtual_account = stored_virtual_account,
      payment_response = payment_payload,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now()),
      expires_at = greatest(coalesce(expires_at, now()), now() + interval '24 hours')
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
  stay_check_in date;
  stay_check_out date;
  has_existing_block boolean;
  payment_payload jsonb := $4;
begin
  perform public.release_expired_pending_stay_blocks();

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

  response_status := coalesce(payment_payload ->> 'status', payment_payload ->> 'paymentStatus');
  response_amount := coalesce(
    case when jsonb_typeof(payment_payload -> 'amount') = 'object' then nullif(payment_payload #>> '{amount,total}', '')::integer else null end,
    case when jsonb_typeof(payment_payload -> 'amount') = 'number' then nullif(payment_payload ->> 'amount', '')::integer else null end,
    nullif(payment_payload ->> 'totalAmount', '')::integer,
    -1
  );

  if coalesce(payment_payload ->> 'id', payment_payload ->> 'paymentId', payment_payload ->> 'orderId') is distinct from intent.order_id
     or response_amount <> intent.amount
     or response_status <> 'PAID' then
    raise exception 'PortOne payment does not match the prepared intent.';
  end if;

  if intent.kind = 'stay' then
    stay_check_in := coalesce((intent.draft ->> 'check_in_date')::date, (intent.draft ->> 'event_date')::date);
    stay_check_out := coalesce((intent.draft ->> 'check_out_date')::date, stay_check_in + 1);

    select exists (
      select 1
      from public.stay_availability_blocks b
      where b.payment_intent_id = intent.id
        and b.status = 'active'
    ) into has_existing_block;

    if not has_existing_block and not public.stay_range_is_available((intent.draft ->> 'offering_id')::uuid, stay_check_in, stay_check_out) then
      raise exception 'This room is no longer available for the selected dates.';
    end if;

    insert into public.reservations (
      business_id, customer_id, offering_id, customer_name, group_name,
      contact_phone, event_date, check_in_date, check_out_date, guest_count,
      offering_name, total_amount, request_memo
    ) values (
      (intent.draft ->> 'business_id')::uuid,
      intent.customer_id,
      (intent.draft ->> 'offering_id')::uuid,
      intent.draft ->> 'customer_name',
      intent.draft ->> 'group_name',
      intent.draft ->> 'contact_phone',
      stay_check_in,
      stay_check_in,
      stay_check_out,
      (intent.draft ->> 'guest_count')::integer,
      intent.draft ->> 'offering_name',
      intent.amount,
      intent.draft ->> 'request_memo'
    ) returning id into new_transaction_id;

    update public.stay_availability_blocks
    set source = 'motf',
        reservation_id = new_transaction_id,
        note = 'moTF paid reservation'
    where payment_intent_id = intent.id
      and status = 'active';

    if not found then
      insert into public.stay_availability_blocks (
        business_id, offering_id, start_date, end_date, source, reservation_id, payment_intent_id, payment_order_id, note
      ) values (
        (intent.draft ->> 'business_id')::uuid,
        (intent.draft ->> 'offering_id')::uuid,
        stay_check_in,
        stay_check_out,
        'motf',
        new_transaction_id,
        intent.id,
        intent.order_id,
        'moTF paid reservation'
      );
    end if;
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
      payment_response = payment_payload,
      paid_at = now(),
      confirmed_at = now()
  where id = intent.id;

  return query select new_transaction_id, intent.kind;
end;
$$;

grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid, text, text, jsonb) to service_role;
