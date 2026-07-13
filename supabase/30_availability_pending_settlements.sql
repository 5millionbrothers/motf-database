-- Pending-payment room blocking and partner settlement automation.
-- Core rule:
-- 1. A stay room is blocked as soon as a virtual account is issued.
-- 2. The pending block turns into a paid reservation block when PortOne reports PAID.
-- 3. Expired/unpaid pending blocks are released before availability checks.

alter table public.stay_availability_blocks
  add column if not exists payment_intent_id uuid references public.payment_intents(id) on delete set null,
  add column if not exists payment_order_id text;

alter table public.stay_availability_blocks
  drop constraint if exists stay_availability_blocks_source_check;

alter table public.stay_availability_blocks
  add constraint stay_availability_blocks_source_check
  check (source in ('manual', 'motf', 'pending_payment', 'external_ical', 'external_api'));

create unique index if not exists stay_blocks_payment_intent_unique_idx
on public.stay_availability_blocks(payment_intent_id)
where payment_intent_id is not null and status = 'active';

create index if not exists stay_blocks_payment_order_idx
on public.stay_availability_blocks(payment_order_id)
where payment_order_id is not null;

create table if not exists public.partner_settlements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  transaction_kind text not null check (transaction_kind in ('stay', 'market')),
  transaction_id uuid not null,
  gross_amount integer not null check (gross_amount >= 0),
  commission_rate numeric(5,4) not null check (commission_rate >= 0 and commission_rate <= 1),
  commission_amount integer not null check (commission_amount >= 0),
  payout_amount integer not null check (payout_amount >= 0),
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled')),
  paid_at timestamptz,
  paid_by uuid references public.profiles(id) on delete set null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists partner_settlements_transaction_unique_idx
on public.partner_settlements(transaction_kind, transaction_id);

create index if not exists partner_settlements_business_status_idx
on public.partner_settlements(business_id, status);

drop trigger if exists partner_settlements_set_updated_at on public.partner_settlements;
create trigger partner_settlements_set_updated_at
before update on public.partner_settlements
for each row execute procedure public.set_updated_at();

alter table public.partner_settlements enable row level security;

drop policy if exists "partner_settlements_read_participants" on public.partner_settlements;
create policy "partner_settlements_read_participants"
on public.partner_settlements
for select
to authenticated
using (public.owns_business(business_id) or public.is_admin());

drop policy if exists "payment_intents_read_partner_business" on public.payment_intents;
create policy "payment_intents_read_partner_business"
on public.payment_intents
for select
to authenticated
using (
  exists (
    select 1
    from public.businesses b
    where b.id::text = payment_intents.draft ->> 'business_id'
      and b.owner_id = auth.uid()
      and b.approval_status = 'approved'
  )
);

grant select on public.partner_settlements to authenticated;

create or replace function public.release_expired_pending_stay_blocks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  released_count integer;
begin
  update public.stay_availability_blocks b
  set status = 'cancelled',
      note = coalesce(b.note, '') || case when b.note is null or b.note = '' then '' else ' / ' end || 'auto released: pending payment expired'
  from public.payment_intents pi
  where b.payment_intent_id = pi.id
    and b.source = 'pending_payment'
    and b.status = 'active'
    and (
      pi.status <> 'virtual_account_issued'
      or coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') <= now()
    );

  get diagnostics released_count = row_count;
  return released_count;
end;
$$;

create or replace function public.stay_range_is_available(
  target_offering_id uuid,
  target_check_in date,
  target_check_out date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select target_check_in < target_check_out
    and not exists (
      select 1
      from public.stay_availability_blocks b
      where b.offering_id = target_offering_id
        and b.status = 'active'
        and b.start_date < target_check_out
        and b.end_date > target_check_in
        and (
          b.source <> 'pending_payment'
          or exists (
            select 1
            from public.payment_intents pi
            where pi.id = b.payment_intent_id
              and pi.status = 'virtual_account_issued'
              and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') > now()
          )
        )
    );
$$;

create or replace function public.list_unavailable_stay_offerings(
  target_check_in date,
  target_check_out date
)
returns table(offering_id uuid, business_id uuid, source text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.release_expired_pending_stay_blocks();

  if target_check_in is null or target_check_out is null or target_check_in >= target_check_out then
    raise exception 'Invalid stay date range.';
  end if;

  return query
  select distinct b.offering_id, b.business_id, b.source
  from public.stay_availability_blocks b
  where b.status = 'active'
    and b.start_date < target_check_out
    and b.end_date > target_check_in
    and (
      b.source <> 'pending_payment'
      or exists (
        select 1
        from public.payment_intents pi
        where pi.id = b.payment_intent_id
          and pi.status = 'virtual_account_issued'
          and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') > now()
      )
    );
end;
$$;

create or replace function public.list_pending_payment_intents(
  target_business_id uuid default null
)
returns table(
  order_id text,
  kind text,
  amount integer,
  order_name text,
  status text,
  virtual_account jsonb,
  virtual_account_issued_at timestamptz,
  created_at timestamptz,
  expires_at timestamptz,
  draft jsonb,
  business_id uuid,
  business_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.release_expired_pending_stay_blocks();

  if target_business_id is not null and not public.owns_business(target_business_id) and not public.is_admin() then
    raise exception 'You do not have permission to read this business.';
  end if;

  if target_business_id is null and not public.is_admin() then
    return query
    select
      pi.order_id,
      pi.kind,
      pi.amount,
      pi.order_name,
      pi.status,
      pi.virtual_account,
      pi.virtual_account_issued_at,
      pi.created_at,
      pi.expires_at,
      pi.draft,
      b.id,
      b.business_name
    from public.payment_intents pi
    join public.businesses b on b.id::text = pi.draft ->> 'business_id'
    where pi.status = 'virtual_account_issued'
      and b.owner_id = auth.uid()
      and b.approval_status = 'approved'
    order by pi.virtual_account_issued_at desc nulls last, pi.created_at desc;
    return;
  end if;

  return query
  select
    pi.order_id,
    pi.kind,
    pi.amount,
    pi.order_name,
    pi.status,
    pi.virtual_account,
    pi.virtual_account_issued_at,
    pi.created_at,
    pi.expires_at,
    pi.draft,
    b.id,
    b.business_name
  from public.payment_intents pi
  join public.businesses b on b.id::text = pi.draft ->> 'business_id'
  where pi.status = 'virtual_account_issued'
    and (target_business_id is null or b.id = target_business_id)
  order by pi.virtual_account_issued_at desc nulls last, pi.created_at desc;
end;
$$;

create or replace function public.create_stay_manual_block(
  target_offering_id uuid,
  target_check_in date,
  target_check_out date,
  block_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  new_block_id uuid;
begin
  perform public.release_expired_pending_stay_blocks();

  select * into selected_offering
  from public.offerings
  where id = target_offering_id;

  if selected_offering.id is null then
    raise exception 'Offering not found.';
  end if;
  if not public.owns_business(selected_offering.business_id) and not public.is_admin() then
    raise exception 'You do not have permission to block this offering.';
  end if;
  if target_check_in is null or target_check_out is null or target_check_in >= target_check_out then
    raise exception 'Invalid block date range.';
  end if;
  if not public.stay_range_is_available(target_offering_id, target_check_in, target_check_out) then
    raise exception 'This date range is already blocked.';
  end if;

  insert into public.stay_availability_blocks (
    business_id, offering_id, start_date, end_date, source, note
  ) values (
    selected_offering.business_id, selected_offering.id, target_check_in, target_check_out, 'manual', nullif(trim(block_note), '')
  ) returning id into new_block_id;

  return new_block_id;
end;
$$;

drop function if exists public.mark_virtual_account_issued(uuid, text, jsonb);
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
    portone_response -> 'virtualAccount',
    portone_response -> 'virtual_account',
    portone_response -> 'virtualAccountIssued',
    portone_response -> 'paymentMethod',
    portone_response -> 'paymentMethodDetail',
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
      pg_provider = coalesce(portone_response ->> 'pgProvider', portone_response ->> 'pg_provider', pg_provider),
      channel_key = coalesce(portone_response ->> 'channelKey', portone_response ->> 'channel_key', channel_key),
      virtual_account = stored_virtual_account,
      payment_response = portone_response,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now()),
      expires_at = greatest(coalesce(expires_at, now()), now() + interval '24 hours')
  where id = intent.id
  returning payment_intents.order_id, payment_intents.status, payment_intents.virtual_account
  into order_id, status, virtual_account;

  return next;
end;
$$;

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
  stay_check_in date;
  stay_check_out date;
  has_existing_block boolean;
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

  response_status := coalesce(portone_response ->> 'status', portone_response ->> 'paymentStatus');
  response_amount := coalesce(
    case when jsonb_typeof(portone_response -> 'amount') = 'object' then nullif(portone_response #>> '{amount,total}', '')::integer else null end,
    case when jsonb_typeof(portone_response -> 'amount') = 'number' then nullif(portone_response ->> 'amount', '')::integer else null end,
    nullif(portone_response ->> 'totalAmount', '')::integer,
    -1
  );

  if coalesce(portone_response ->> 'id', portone_response ->> 'paymentId', portone_response ->> 'orderId') is distinct from intent.order_id
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
      payment_response = portone_response,
      paid_at = now(),
      confirmed_at = now()
  where id = intent.id;

  return query select new_transaction_id, intent.kind;
end;
$$;

create or replace function public.set_reservation_status(
  target_reservation_id uuid,
  new_status text,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business uuid;
  target_amount integer;
  target_current_status text;
  has_confirmed_payment boolean;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Invalid reservation status.';
  end if;

  select business_id, total_amount, status
  into target_business, target_amount, target_current_status
  from public.reservations
  where id = target_reservation_id;

  if target_business is null then
    raise exception 'Reservation not found.';
  end if;

  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception 'You do not have permission to handle this reservation.';
  end if;

  if target_current_status in ('rejected', 'cancelled', 'completed') then
    raise exception 'Closed reservations cannot be changed.';
  end if;

  select exists (
    select 1
    from public.payment_intents
    where kind = 'stay'
      and transaction_id = target_reservation_id
      and status = 'confirmed'
      and payment_key is not null
  ) into has_confirmed_payment;

  update public.reservations
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      payment_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'refund_required'
        else payment_status
      end,
      refund_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'required'
        when new_status = 'rejected' then 'none'
        else refund_status
      end,
      refund_amount = case
        when new_status = 'rejected' and has_confirmed_payment then total_amount
        when new_status = 'rejected' then null
        else refund_amount
      end,
      refund_reason = case
        when new_status = 'rejected' and has_confirmed_payment then coalesce(nullif(reason, ''), 'Reservation rejected')
        when new_status = 'rejected' then null
        else refund_reason
      end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_reservation_id;

  if new_status in ('rejected', 'cancelled') then
    update public.stay_availability_blocks
    set status = 'cancelled',
        note = coalesce(note, '') || case when note is null or note = '' then '' else ' / ' end || 'reservation closed'
    where reservation_id = target_reservation_id
      and status = 'active';
  end if;

  if new_status = 'rejected' and has_confirmed_payment then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), 'Reservation rejected')
    where kind = 'stay'
      and transaction_id = target_reservation_id
      and status = 'confirmed';
  end if;
end;
$$;

create or replace function public.sync_partner_settlements()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_count integer := 0;
  row_count_value integer;
begin
  insert into public.partner_settlements (
    business_id, transaction_kind, transaction_id,
    gross_amount, commission_rate, commission_amount, payout_amount
  )
  select
    r.business_id,
    'stay',
    r.id,
    r.total_amount,
    0.07,
    floor(r.total_amount * 0.07)::integer,
    r.total_amount - floor(r.total_amount * 0.07)::integer
  from public.reservations r
  where r.status in ('confirmed', 'completed')
  on conflict (transaction_kind, transaction_id) do update
  set business_id = excluded.business_id,
      gross_amount = excluded.gross_amount,
      commission_rate = excluded.commission_rate,
      commission_amount = excluded.commission_amount,
      payout_amount = excluded.payout_amount,
      status = case when public.partner_settlements.status = 'cancelled' then 'pending' else public.partner_settlements.status end;

  get diagnostics row_count_value = row_count;
  affected_count := affected_count + row_count_value;

  insert into public.partner_settlements (
    business_id, transaction_kind, transaction_id,
    gross_amount, commission_rate, commission_amount, payout_amount
  )
  select
    o.business_id,
    'market',
    o.id,
    o.total_amount,
    0.05,
    floor(o.total_amount * 0.05)::integer,
    o.total_amount - floor(o.total_amount * 0.05)::integer
  from public.market_orders o
  where o.status in ('confirmed', 'completed')
  on conflict (transaction_kind, transaction_id) do update
  set business_id = excluded.business_id,
      gross_amount = excluded.gross_amount,
      commission_rate = excluded.commission_rate,
      commission_amount = excluded.commission_amount,
      payout_amount = excluded.payout_amount,
      status = case when public.partner_settlements.status = 'cancelled' then 'pending' else public.partner_settlements.status end;

  get diagnostics row_count_value = row_count;
  affected_count := affected_count + row_count_value;

  update public.partner_settlements s
  set status = 'cancelled'
  where s.status = 'pending'
    and (
      (s.transaction_kind = 'stay' and not exists (
        select 1 from public.reservations r
        where r.id = s.transaction_id and r.status in ('confirmed', 'completed')
      ))
      or
      (s.transaction_kind = 'market' and not exists (
        select 1 from public.market_orders o
        where o.id = s.transaction_id and o.status in ('confirmed', 'completed')
      ))
    );

  return affected_count;
end;
$$;

create or replace function public.list_partner_settlements()
returns table(
  id uuid,
  business_id uuid,
  business_name text,
  business_type text,
  transaction_kind text,
  transaction_id uuid,
  customer_name text,
  target_name text,
  transaction_date date,
  gross_amount integer,
  commission_rate numeric,
  commission_amount integer,
  payout_amount integer,
  status text,
  paid_at timestamptz,
  note text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin permission is required.';
  end if;

  perform public.sync_partner_settlements();

  return query
  select
    s.id,
    s.business_id,
    b.business_name,
    b.business_type,
    s.transaction_kind,
    s.transaction_id,
    coalesce(r.customer_name, o.customer_name) as customer_name,
    coalesce(r.offering_name, (
      select string_agg(moi.item_name || ' ' || moi.quantity || '개', ', ' order by moi.item_name)
      from public.market_order_items moi
      where moi.order_id = o.id
    ), '거래') as target_name,
    coalesce(r.event_date, o.created_at::date) as transaction_date,
    s.gross_amount,
    s.commission_rate,
    s.commission_amount,
    s.payout_amount,
    s.status,
    s.paid_at,
    s.note
  from public.partner_settlements s
  join public.businesses b on b.id = s.business_id
  left join public.reservations r on s.transaction_kind = 'stay' and r.id = s.transaction_id
  left join public.market_orders o on s.transaction_kind = 'market' and o.id = s.transaction_id
  where s.status <> 'cancelled'
  order by s.created_at desc;
end;
$$;

create or replace function public.mark_partner_settlement_paid(
  target_settlement_id uuid,
  payment_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin permission is required.';
  end if;

  update public.partner_settlements
  set status = 'paid',
      paid_at = now(),
      paid_by = auth.uid(),
      note = nullif(trim(payment_note), '')
  where id = target_settlement_id
    and status = 'pending';

  if not found then
    raise exception 'Settlement was not found or is not pending.';
  end if;
end;
$$;

revoke all on function public.release_expired_pending_stay_blocks() from public;
revoke all on function public.list_unavailable_stay_offerings(date, date) from public;
revoke all on function public.list_pending_payment_intents(uuid) from public;
revoke all on function public.create_stay_manual_block(uuid, date, date, text) from public;
revoke all on function public.mark_virtual_account_issued(uuid, text, jsonb) from public;
revoke all on function public.finalize_payment_intent(uuid, text, text, jsonb) from public;
revoke all on function public.set_reservation_status(uuid, text, text) from public;
revoke all on function public.sync_partner_settlements() from public;
revoke all on function public.list_partner_settlements() from public;
revoke all on function public.mark_partner_settlement_paid(uuid, text) from public;

grant execute on function public.release_expired_pending_stay_blocks() to authenticated, service_role;
grant execute on function public.list_unavailable_stay_offerings(date, date) to anon, authenticated;
grant execute on function public.list_pending_payment_intents(uuid) to authenticated;
grant execute on function public.create_stay_manual_block(uuid, date, date, text) to authenticated;
grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid, text, text, jsonb) to service_role;
grant execute on function public.set_reservation_status(uuid, text, text) to authenticated;
grant execute on function public.sync_partner_settlements() to authenticated;
grant execute on function public.list_partner_settlements() to authenticated;
grant execute on function public.mark_partner_settlement_paid(uuid, text) to authenticated;
