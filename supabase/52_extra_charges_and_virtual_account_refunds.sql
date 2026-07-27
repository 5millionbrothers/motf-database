-- Post-booking extra charges and virtual-account refund account storage.

alter table public.reservations
  add column if not exists base_accommodation_amount integer check (base_accommodation_amount is null or base_accommodation_amount >= 0),
  add column if not exists extra_charges_total integer not null default 0 check (extra_charges_total >= 0),
  add column if not exists pricing_breakdown jsonb not null default '[]'::jsonb,
  add column if not exists customer_cancelled_at timestamptz,
  add column if not exists cancellation_refund_percent integer check (cancellation_refund_percent is null or cancellation_refund_percent between 0 and 100);

update public.reservations
set base_accommodation_amount = coalesce(base_accommodation_amount, total_amount)
where base_accommodation_amount is null;

create table if not exists public.customer_refund_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bank text not null check (char_length(trim(bank)) between 2 and 40),
  account_number text not null check (char_length(regexp_replace(account_number, '[^0-9]', '', 'g')) between 8 and 20),
  holder_name text not null check (char_length(trim(holder_name)) between 2 and 50),
  phone text,
  consent_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists customer_refund_accounts_set_updated_at on public.customer_refund_accounts;
create trigger customer_refund_accounts_set_updated_at before update on public.customer_refund_accounts
for each row execute procedure public.set_updated_at();

alter table public.customer_refund_accounts enable row level security;
drop policy if exists "refund_accounts_own_read" on public.customer_refund_accounts;
create policy "refund_accounts_own_read" on public.customer_refund_accounts
for select to authenticated using (user_id = auth.uid());
drop policy if exists "refund_accounts_own_insert" on public.customer_refund_accounts;
create policy "refund_accounts_own_insert" on public.customer_refund_accounts
for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "refund_accounts_own_update" on public.customer_refund_accounts;
create policy "refund_accounts_own_update" on public.customer_refund_accounts
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.customer_refund_accounts to authenticated;
grant select on public.customer_refund_accounts to service_role;

create table if not exists public.reservation_extra_charge_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  requested_by uuid references public.profiles(id) on delete set null,
  reviewed_by uuid references public.profiles(id) on delete set null,
  items jsonb not null,
  total_amount integer not null check (total_amount > 0),
  owner_note text,
  review_note text,
  status text not null default 'submitted' check (status in (
    'submitted','approved','payment_prepared','payment_pending','paid','rejected','cancelled','expired'
  )),
  due_at timestamptz,
  payment_intent_id uuid,
  paid_at timestamptz,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) > 0)
);

create index if not exists reservation_extra_charges_reservation_idx
on public.reservation_extra_charge_requests(reservation_id, created_at desc);
create index if not exists reservation_extra_charges_business_status_idx
on public.reservation_extra_charge_requests(business_id, status, created_at desc);
create index if not exists reservation_extra_charges_customer_status_idx
on public.reservation_extra_charge_requests(customer_id, status, created_at desc);

drop trigger if exists reservation_extra_charge_requests_set_updated_at on public.reservation_extra_charge_requests;
create trigger reservation_extra_charge_requests_set_updated_at before update on public.reservation_extra_charge_requests
for each row execute procedure public.set_updated_at();

alter table public.reservation_extra_charge_requests enable row level security;
drop policy if exists "extra_charge_requests_read_participants" on public.reservation_extra_charge_requests;
create policy "extra_charge_requests_read_participants" on public.reservation_extra_charge_requests
for select to authenticated using (
  customer_id = auth.uid() or public.owns_business(business_id) or public.is_admin()
);
grant select on public.reservation_extra_charge_requests to authenticated;
grant select, insert, update on public.reservation_extra_charge_requests to service_role;

alter table public.payment_intents
  add column if not exists extra_charge_request_id uuid references public.reservation_extra_charge_requests(id) on delete set null;

alter table public.reservation_extra_charge_requests
  drop constraint if exists reservation_extra_charge_requests_payment_intent_id_fkey;
alter table public.reservation_extra_charge_requests
  add constraint reservation_extra_charge_requests_payment_intent_id_fkey
  foreign key (payment_intent_id) references public.payment_intents(id) on delete set null;

alter table public.payment_intents drop constraint if exists payment_intents_kind_check;
alter table public.payment_intents add constraint payment_intents_kind_check
check (kind in ('stay', 'market', 'extra_charge'));

alter table public.partner_settlements drop constraint if exists partner_settlements_transaction_kind_check;
alter table public.partner_settlements add constraint partner_settlements_transaction_kind_check
check (transaction_kind in ('stay', 'market', 'extra_charge'));

create or replace function public.create_reservation_extra_charge_request(
  target_reservation_id uuid,
  charge_items jsonb,
  request_note text default null,
  payment_due_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_reservation public.reservations%rowtype;
  calculated_total bigint;
  new_request_id uuid;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select * into target_reservation from public.reservations where id = target_reservation_id;
  if target_reservation.id is null then raise exception '예약을 찾을 수 없습니다.'; end if;
  if not public.owns_business(target_reservation.business_id) and not public.is_admin() then
    raise exception '추가금 요청 권한이 없습니다.';
  end if;
  if target_reservation.status not in ('confirmed', 'completed') then
    raise exception '확정된 예약에만 추가금을 요청할 수 있습니다.';
  end if;
  if jsonb_typeof(charge_items) <> 'array' or jsonb_array_length(charge_items) = 0 then
    raise exception '추가금 항목을 하나 이상 입력해주세요.';
  end if;

  select sum(
    greatest(coalesce(nullif(item->>'quantity','')::integer, 1), 1)
    * greatest(coalesce(nullif(item->>'unit_amount','')::integer, 0), 0)
  ) into calculated_total
  from jsonb_array_elements(charge_items) item
  where nullif(trim(item->>'label'), '') is not null;

  if coalesce(calculated_total, 0) <= 0 or calculated_total > 100000000 then
    raise exception '추가금 합계를 확인해주세요.';
  end if;

  insert into public.reservation_extra_charge_requests (
    reservation_id, business_id, customer_id, requested_by, items,
    total_amount, owner_note, due_at, status
  ) values (
    target_reservation.id, target_reservation.business_id, target_reservation.customer_id,
    auth.uid(), charge_items, calculated_total::integer, nullif(trim(request_note), ''),
    payment_due_at,
    case when public.is_admin() then 'approved' else 'submitted' end
  ) returning id into new_request_id;

  if public.is_admin() then
    update public.reservation_extra_charge_requests
    set reviewed_by = auth.uid(), reviewed_at = now(), review_note = '운영팀 직접 등록'
    where id = new_request_id;
  end if;
  return new_request_id;
end;
$$;

create or replace function public.review_reservation_extra_charge_request(
  target_request_id uuid,
  review_decision text,
  note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  if review_decision not in ('approved', 'rejected') then raise exception '검토 결과가 올바르지 않습니다.'; end if;
  update public.reservation_extra_charge_requests
  set status = review_decision,
      review_note = nullif(trim(note), ''),
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = target_request_id and status = 'submitted';
  if not found then raise exception '검토 가능한 추가금 요청을 찾지 못했습니다.'; end if;
end;
$$;

create or replace function public.prepare_extra_charge_payment(target_request_id uuid)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  charge_request public.reservation_extra_charge_requests%rowtype;
  target_business public.businesses%rowtype;
  target_reservation public.reservations%rowtype;
  existing_intent public.payment_intents%rowtype;
  new_intent_id uuid;
  new_order_id text;
  new_order_name text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select * into charge_request from public.reservation_extra_charge_requests
  where id = target_request_id and customer_id = auth.uid() for update;
  if charge_request.id is null then raise exception '추가금 요청을 찾을 수 없습니다.'; end if;
  if charge_request.status = 'paid' then raise exception '이미 결제된 추가금입니다.'; end if;
  if charge_request.status not in ('approved', 'payment_prepared', 'payment_pending', 'expired') then
    raise exception '아직 결제할 수 없는 추가금 요청입니다.';
  end if;
  if charge_request.due_at is not null and charge_request.due_at <= now() then
    update public.reservation_extra_charge_requests set status = 'expired' where id = charge_request.id;
    raise exception '추가금 결제 기한이 지났습니다. 운영팀에 문의해주세요.';
  end if;
  if not exists (select 1 from public.customer_refund_accounts where user_id = auth.uid()) then
    raise exception '자동 환불을 위한 환불계좌를 먼저 등록해주세요.';
  end if;

  if charge_request.payment_intent_id is not null then
    select * into existing_intent from public.payment_intents where id = charge_request.payment_intent_id;
    if existing_intent.id is not null
       and existing_intent.status in ('prepared', 'virtual_account_issued')
       and existing_intent.expires_at > now() then
      return query select existing_intent.order_id, existing_intent.amount,
        existing_intent.order_name, existing_intent.kind;
      return;
    end if;
  end if;

  select * into target_business from public.businesses where id = charge_request.business_id;
  select * into target_reservation from public.reservations where id = charge_request.reservation_id;
  new_order_name := left(target_business.business_name || ' 추가 이용금', 100);
  loop
    new_order_id := 'ME-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (select 1 from public.payment_intents pi where pi.order_id = new_order_id);
  end loop;

  insert into public.payment_intents (
    order_id, customer_id, kind, amount, order_name, draft, extra_charge_request_id
  ) values (
    new_order_id, auth.uid(), 'extra_charge', charge_request.total_amount, new_order_name,
    jsonb_build_object(
      'business_id', charge_request.business_id,
      'reservation_id', charge_request.reservation_id,
      'extra_charge_request_id', charge_request.id,
      'customer_name', target_reservation.customer_name,
      'contact_phone', target_reservation.contact_phone,
      'offering_name', target_reservation.offering_name,
      'items', charge_request.items
    ), charge_request.id
  ) returning id into new_intent_id;

  update public.reservation_extra_charge_requests
  set payment_intent_id = new_intent_id, status = 'payment_prepared'
  where id = charge_request.id;
  return query select new_order_id, charge_request.total_amount, new_order_name, 'extra_charge'::text;
end;
$$;

revoke all on function public.create_reservation_extra_charge_request(uuid,jsonb,text,timestamptz) from public;
revoke all on function public.review_reservation_extra_charge_request(uuid,text,text) from public;
revoke all on function public.prepare_extra_charge_payment(uuid) from public;
grant execute on function public.create_reservation_extra_charge_request(uuid,jsonb,text,timestamptz) to authenticated;
grant execute on function public.review_reservation_extra_charge_request(uuid,text,text) to authenticated;
grant execute on function public.prepare_extra_charge_payment(uuid) to authenticated;

create or replace function public.sync_extra_charge_request_from_intent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind <> 'extra_charge' or new.extra_charge_request_id is null
     or new.status is not distinct from old.status then
    return new;
  end if;

  if new.status = 'expired' then
    update public.reservation_extra_charge_requests
    set status = 'expired'
    where id = new.extra_charge_request_id
      and status in ('payment_prepared', 'payment_pending');
  elsif new.status in ('cancelled', 'failed') then
    update public.reservation_extra_charge_requests
    set status = 'cancelled'
    where id = new.extra_charge_request_id
      and status in ('approved', 'payment_prepared', 'payment_pending', 'expired');
  end if;
  return new;
end;
$$;

drop trigger if exists sync_extra_charge_intent_status on public.payment_intents;
create trigger sync_extra_charge_intent_status
after update of status on public.payment_intents
for each row execute function public.sync_extra_charge_request_from_intent();

create or replace function public.cancel_open_extra_charges_with_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('cancelled', 'rejected') and new.status is distinct from old.status then
    update public.reservation_extra_charge_requests
    set status = 'cancelled',
        review_note = coalesce(review_note, '예약 취소로 결제 요청이 종료되었습니다.')
    where reservation_id = new.id
      and status in ('submitted', 'approved', 'payment_prepared', 'payment_pending', 'expired');
  end if;
  return new;
end;
$$;

drop trigger if exists cancel_extra_charges_on_reservation_close on public.reservations;
create trigger cancel_extra_charges_on_reservation_close
after update of status on public.reservations
for each row execute function public.cancel_open_extra_charges_with_reservation();

revoke all on function public.sync_extra_charge_request_from_intent() from public;
revoke all on function public.cancel_open_extra_charges_with_reservation() from public;

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
  select * into intent from public.payment_intents
  where payment_intents.order_id = target_order_id for update;
  if intent.id is null or intent.customer_id <> target_customer_id then raise exception 'Payment intent not found.'; end if;
  if intent.status = 'confirmed' then
    return query select intent.order_id, intent.status, intent.virtual_account; return;
  end if;
  if intent.status not in ('prepared', 'virtual_account_issued') then
    raise exception 'Payment intent cannot be marked as virtual-account issued.';
  end if;

  stored_virtual_account := coalesce(
    payment_payload -> 'virtualAccount', payment_payload -> 'virtual_account',
    payment_payload -> 'virtualAccountIssued', payment_payload -> 'virtual_account_issued',
    payment_payload -> 'paymentMethod', payment_payload -> 'payment_method',
    payment_payload -> 'paymentMethodDetail', payment_payload -> 'payment_method_detail', '{}'::jsonb
  );

  if intent.kind = 'stay' then
    stay_check_in := coalesce((intent.draft ->> 'check_in_date')::date, (intent.draft ->> 'event_date')::date);
    stay_check_out := coalesce((intent.draft ->> 'check_out_date')::date, stay_check_in + 1);
    if not exists (select 1 from public.stay_availability_blocks b where b.payment_intent_id = intent.id and b.status = 'active') then
      if not public.stay_range_is_available((intent.draft ->> 'offering_id')::uuid, stay_check_in, stay_check_out) then
        raise exception 'This room is already blocked for the selected dates.';
      end if;
      insert into public.stay_availability_blocks (
        business_id, offering_id, start_date, end_date, source, payment_intent_id, payment_order_id, note
      ) values (
        (intent.draft ->> 'business_id')::uuid, (intent.draft ->> 'offering_id')::uuid,
        stay_check_in, stay_check_out, 'pending_payment', intent.id, intent.order_id,
        'PortOne virtual account issued'
      );
    end if;
  end if;

  update public.payment_intents
  set status = 'virtual_account_issued', provider = 'portone',
      pg_provider = coalesce(payment_payload ->> 'pgProvider', payment_payload ->> 'pg_provider', pg_provider),
      channel_key = coalesce(payment_payload ->> 'channelKey', payment_payload ->> 'channel_key', channel_key),
      virtual_account = stored_virtual_account, payment_response = payment_payload,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now()),
      expires_at = greatest(coalesce(expires_at, now()), now() + interval '24 hours')
  where id = intent.id
  returning payment_intents.order_id, payment_intents.status, payment_intents.virtual_account
  into order_id, status, virtual_account;

  if intent.kind = 'extra_charge' and intent.extra_charge_request_id is not null then
    update public.reservation_extra_charge_requests
    set status = 'payment_pending'
    where id = intent.extra_charge_request_id and status in ('approved','payment_prepared','expired');
  end if;
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
  select * into intent from public.payment_intents where order_id = target_order_id for update;
  if intent.id is null or intent.customer_id <> target_customer_id then raise exception 'Payment intent not found.'; end if;
  if intent.status = 'confirmed' then return query select intent.transaction_id, intent.kind; return; end if;
  if intent.status not in ('prepared', 'virtual_account_issued') then raise exception 'Payment intent cannot be finalized.'; end if;

  response_status := coalesce(payment_payload ->> 'status', payment_payload ->> 'paymentStatus');
  response_amount := coalesce(
    case when jsonb_typeof(payment_payload -> 'amount') = 'object' then nullif(payment_payload #>> '{amount,total}', '')::integer else null end,
    case when jsonb_typeof(payment_payload -> 'amount') = 'number' then nullif(payment_payload ->> 'amount', '')::integer else null end,
    nullif(payment_payload ->> 'totalAmount', '')::integer, -1
  );
  if coalesce(payment_payload ->> 'id', payment_payload ->> 'paymentId', payment_payload ->> 'orderId') is distinct from intent.order_id
     or response_amount <> intent.amount or response_status <> 'PAID' then
    raise exception 'PortOne payment does not match the prepared intent.';
  end if;

  if intent.kind = 'stay' then
    stay_check_in := coalesce((intent.draft ->> 'check_in_date')::date, (intent.draft ->> 'event_date')::date);
    stay_check_out := coalesce((intent.draft ->> 'check_out_date')::date, stay_check_in + 1);
    select exists (select 1 from public.stay_availability_blocks b where b.payment_intent_id = intent.id and b.status = 'active')
    into has_existing_block;
    if not has_existing_block and not public.stay_range_is_available((intent.draft ->> 'offering_id')::uuid, stay_check_in, stay_check_out) then
      raise exception 'This room is no longer available for the selected dates.';
    end if;
    insert into public.reservations (
      business_id, customer_id, offering_id, customer_name, group_name, contact_phone,
      event_date, check_in_date, check_out_date, guest_count, offering_name,
      total_amount, base_accommodation_amount, request_memo
    ) values (
      (intent.draft ->> 'business_id')::uuid, intent.customer_id,
      (intent.draft ->> 'offering_id')::uuid, intent.draft ->> 'customer_name',
      intent.draft ->> 'group_name', intent.draft ->> 'contact_phone', stay_check_in,
      stay_check_in, stay_check_out, (intent.draft ->> 'guest_count')::integer,
      intent.draft ->> 'offering_name', intent.amount, intent.amount, intent.draft ->> 'request_memo'
    ) returning id into new_transaction_id;
    update public.stay_availability_blocks
    set source = 'motf', reservation_id = new_transaction_id, note = 'moTF paid reservation'
    where payment_intent_id = intent.id and status = 'active';
    if not found then
      insert into public.stay_availability_blocks (
        business_id, offering_id, start_date, end_date, source, reservation_id,
        payment_intent_id, payment_order_id, note
      ) values (
        (intent.draft ->> 'business_id')::uuid, (intent.draft ->> 'offering_id')::uuid,
        stay_check_in, stay_check_out, 'motf', new_transaction_id, intent.id, intent.order_id,
        'moTF paid reservation'
      );
    end if;
  elsif intent.kind = 'market' then
    insert into public.market_orders (
      business_id, customer_id, customer_name, contact_phone, pickup_place,
      pickup_time, request_memo, total_amount
    ) values (
      (intent.draft ->> 'business_id')::uuid, intent.customer_id,
      intent.draft ->> 'customer_name', intent.draft ->> 'contact_phone',
      intent.draft ->> 'pickup_place', (intent.draft ->> 'pickup_time')::time,
      intent.draft ->> 'request_memo', intent.amount
    ) returning id into new_transaction_id;
    insert into public.market_order_items (order_id, offering_id, item_name, quantity, unit_price)
    select new_transaction_id, item.offering_id, item.item_name, item.quantity, item.unit_price
    from jsonb_to_recordset(intent.draft -> 'items') as item(
      offering_id uuid, item_name text, quantity integer, unit_price integer
    );
  elsif intent.kind = 'extra_charge' then
    new_transaction_id := coalesce(intent.extra_charge_request_id, (intent.draft ->> 'extra_charge_request_id')::uuid);
    update public.reservation_extra_charge_requests
    set status = 'paid', paid_at = now(), payment_intent_id = intent.id
    where id = new_transaction_id and customer_id = intent.customer_id;
    if not found then raise exception 'Extra charge request was not found.'; end if;
    update public.reservations r
    set extra_charges_total = coalesce((
          select sum(e.total_amount)::integer from public.reservation_extra_charge_requests e
          where e.reservation_id = r.id and e.status = 'paid'
        ), 0),
        total_amount = coalesce(r.base_accommodation_amount, r.total_amount) + coalesce((
          select sum(e.total_amount)::integer from public.reservation_extra_charge_requests e
          where e.reservation_id = r.id and e.status = 'paid'
        ), 0),
        updated_at = now()
    where r.id = (intent.draft ->> 'reservation_id')::uuid;
  else
    raise exception 'Unsupported payment intent kind.';
  end if;

  update public.payment_intents
  set status = 'confirmed', payment_key = target_payment_key, transaction_id = new_transaction_id,
      provider = 'portone', payment_response = payment_payload, paid_at = now(), confirmed_at = now()
  where id = intent.id;
  return query select new_transaction_id, intent.kind;
end;
$$;

revoke all on function public.mark_virtual_account_issued(uuid,text,jsonb) from public;
revoke all on function public.finalize_payment_intent(uuid,text,text,jsonb) from public;
grant execute on function public.mark_virtual_account_issued(uuid,text,jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid,text,text,jsonb) to service_role;

create or replace function public.sync_partner_settlements()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare affected_count integer := 0; row_count_value integer;
begin
  insert into public.partner_settlements (
    business_id, transaction_kind, transaction_id, gross_amount,
    commission_rate, commission_amount, payout_amount
  )
  select r.business_id, 'stay', r.id, coalesce(r.base_accommodation_amount, r.total_amount),
    0.07, floor(coalesce(r.base_accommodation_amount, r.total_amount) * 0.07)::integer,
    coalesce(r.base_accommodation_amount, r.total_amount) - floor(coalesce(r.base_accommodation_amount, r.total_amount) * 0.07)::integer
  from public.reservations r where r.status in ('confirmed','completed')
  on conflict (transaction_kind, transaction_id) do update set
    business_id=excluded.business_id, gross_amount=excluded.gross_amount,
    commission_rate=excluded.commission_rate, commission_amount=excluded.commission_amount,
    payout_amount=excluded.payout_amount,
    status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics row_count_value = row_count; affected_count := affected_count + row_count_value;

  insert into public.partner_settlements (
    business_id, transaction_kind, transaction_id, gross_amount,
    commission_rate, commission_amount, payout_amount
  )
  select o.business_id, 'market', o.id, o.total_amount, 0.05,
    floor(o.total_amount * 0.05)::integer, o.total_amount - floor(o.total_amount * 0.05)::integer
  from public.market_orders o where o.status in ('confirmed','completed')
  on conflict (transaction_kind, transaction_id) do update set
    business_id=excluded.business_id, gross_amount=excluded.gross_amount,
    commission_rate=excluded.commission_rate, commission_amount=excluded.commission_amount,
    payout_amount=excluded.payout_amount,
    status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics row_count_value = row_count; affected_count := affected_count + row_count_value;

  insert into public.partner_settlements (
    business_id, transaction_kind, transaction_id, gross_amount,
    commission_rate, commission_amount, payout_amount
  )
  select e.business_id, 'extra_charge', e.id, e.total_amount, 0.07,
    floor(e.total_amount * 0.07)::integer, e.total_amount - floor(e.total_amount * 0.07)::integer
  from public.reservation_extra_charge_requests e where e.status = 'paid'
  on conflict (transaction_kind, transaction_id) do update set
    business_id=excluded.business_id, gross_amount=excluded.gross_amount,
    commission_rate=excluded.commission_rate, commission_amount=excluded.commission_amount,
    payout_amount=excluded.payout_amount,
    status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics row_count_value = row_count; affected_count := affected_count + row_count_value;

  update public.partner_settlements s set status='cancelled'
  where s.status='pending' and (
    (s.transaction_kind='stay' and not exists(select 1 from public.reservations r where r.id=s.transaction_id and r.status in ('confirmed','completed')))
    or (s.transaction_kind='market' and not exists(select 1 from public.market_orders o where o.id=s.transaction_id and o.status in ('confirmed','completed')))
    or (s.transaction_kind='extra_charge' and not exists(select 1 from public.reservation_extra_charge_requests e where e.id=s.transaction_id and e.status='paid'))
  );
  return affected_count;
end;
$$;

drop function if exists public.list_partner_settlements();
create function public.list_partner_settlements()
returns table(
  id uuid, business_id uuid, business_name text, business_type text,
  transaction_kind text, transaction_id uuid, customer_name text,
  target_name text, transaction_date date, gross_amount integer,
  commission_rate numeric, commission_amount integer, payout_amount integer,
  status text, paid_at timestamptz, note text
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'Admin permission is required.'; end if;
  perform public.sync_partner_settlements();
  return query
  select s.id, s.business_id, b.business_name, b.business_type, s.transaction_kind,
    s.transaction_id, coalesce(r.customer_name, o.customer_name, er.customer_name),
    coalesce(r.offering_name, (
      select string_agg(moi.item_name || ' ' || moi.quantity || '개', ', ' order by moi.item_name)
      from public.market_order_items moi where moi.order_id=o.id
    ), case when e.id is not null then er.offering_name || ' 추가 이용금' else '거래' end),
    coalesce(r.event_date, o.created_at::date, e.created_at::date), s.gross_amount,
    s.commission_rate, s.commission_amount, s.payout_amount, s.status, s.paid_at, s.note
  from public.partner_settlements s
  join public.businesses b on b.id=s.business_id
  left join public.reservations r on s.transaction_kind='stay' and r.id=s.transaction_id
  left join public.market_orders o on s.transaction_kind='market' and o.id=s.transaction_id
  left join public.reservation_extra_charge_requests e on s.transaction_kind='extra_charge' and e.id=s.transaction_id
  left join public.reservations er on er.id=e.reservation_id
  where s.status <> 'cancelled' order by s.created_at desc;
end;
$$;

revoke all on function public.sync_partner_settlements() from public;
revoke all on function public.list_partner_settlements() from public;
grant execute on function public.sync_partner_settlements() to authenticated;
grant execute on function public.list_partner_settlements() to authenticated;

insert into public.notification_templates (template_key, audience, title, body, buttons, memo)
values
  ('OWNER_EXTRA_CHARGE_SUBMITTED_V1','owner','추가금 검토 접수','추가금 요청이 운영팀 검토에 접수되었습니다.','[{"name":"요청 확인","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('ADMIN_EXTRA_CHARGE_REVIEW_V1','admin','추가금 검토 필요','사장님이 추가금 요청을 등록했습니다.','[{"name":"검토하기","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('USER_EXTRA_CHARGE_PAYMENT_REQUEST_V1','user','추가금 결제 요청','숙소 추가 이용금 결제 요청이 도착했습니다.','[{"name":"결제하기","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('USER_EXTRA_CHARGE_PAID_V1','user','추가금 입금 확인','추가 이용금 입금이 확인되었습니다.','[{"name":"이용내역 보기","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('OWNER_EXTRA_CHARGE_PAID_V1','owner','추가금 입금 확인','이용자의 추가금 입금이 확인되었습니다.','[{"name":"예약 확인","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('ADMIN_EXTRA_CHARGE_PAID_V1','admin','추가금 입금 확인','추가 이용금 입금이 확인되었습니다.','[{"name":"결제 확인","type":"WL"}]'::jsonb,'추가금 MVP'),
  ('OWNER_EXTRA_CHARGE_REJECTED_V1','owner','추가금 요청 반려','운영팀이 추가금 요청을 반려했습니다.','[{"name":"요청 확인","type":"WL"}]'::jsonb,'추가금 MVP')
on conflict (template_key) do update set
  audience=excluded.audience, title=excluded.title, body=excluded.body,
  buttons=excluded.buttons, memo=excluded.memo, updated_at=now();

create or replace function public.enqueue_extra_charge_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  target_reservation public.reservations%rowtype;
  owner_profile public.profiles%rowtype;
  customer_profile public.profiles%rowtype;
  owner_link text;
  user_link text;
begin
  select * into target_business from public.businesses where id=new.business_id;
  select * into target_reservation from public.reservations where id=new.reservation_id;
  select * into owner_profile from public.profiles where id=target_business.owner_id;
  select * into customer_profile from public.profiles where id=new.customer_id;
  owner_link := public.notification_owner_url('/?section=extraCharges&requestId=' || new.id::text);
  user_link := public.notification_user_url('/?route=myUsage&extraChargeId=' || new.id::text);

  if tg_op='INSERT' and new.status='submitted' then
    if nullif(trim(coalesce(owner_profile.phone,target_business.phone,'')),'') is not null then
      perform public.enqueue_notification(
        target_event_key:='extra_charge_submitted', target_template_key:='OWNER_EXTRA_CHARGE_SUBMITTED_V1',
        target_recipient_role:='owner', target_recipient_user_id:=target_business.owner_id,
        target_recipient_name:=coalesce(owner_profile.full_name,target_business.representative_name,'사장님'),
        target_recipient_phone:=coalesce(owner_profile.phone,target_business.phone),
        target_payload:=jsonb_build_object('숙소명',target_business.business_name,'예약번호',new.reservation_id::text,'추가금',public.notification_money(new.total_amount)),
        target_button_links:=jsonb_build_object('요청 확인',owner_link),
        target_dedupe_key:='extra_charge:'||new.id::text||':submitted:owner'
      );
    end if;
    perform public.enqueue_admin_notifications(
      p_event_key:='extra_charge_review', p_template_key:='ADMIN_EXTRA_CHARGE_REVIEW_V1',
      p_payload:=jsonb_build_object('숙소명',target_business.business_name,'예약번호',new.reservation_id::text,'추가금',public.notification_money(new.total_amount)),
      p_button_links:=jsonb_build_object('검토하기',owner_link),
      p_dedupe_prefix:='extra_charge:'||new.id::text||':review'
    );
  end if;

  if (tg_op='INSERT' and new.status='approved')
     or (tg_op='UPDATE' and new.status='approved' and old.status is distinct from new.status) then
    if nullif(trim(coalesce(target_reservation.contact_phone,customer_profile.phone,'')),'') is not null then
      perform public.enqueue_notification(
        target_event_key:='extra_charge_approved', target_template_key:='USER_EXTRA_CHARGE_PAYMENT_REQUEST_V1',
        target_recipient_role:='user', target_recipient_user_id:=new.customer_id,
        target_recipient_name:=coalesce(target_reservation.customer_name,customer_profile.full_name,'이용자'),
        target_recipient_phone:=coalesce(target_reservation.contact_phone,customer_profile.phone),
        target_payload:=jsonb_build_object('숙소명',target_business.business_name,'객실명',target_reservation.offering_name,'추가금',public.notification_money(new.total_amount),'결제기한',coalesce(new.due_at::text,'별도 안내')),
        target_button_links:=jsonb_build_object('결제하기',user_link),
        target_dedupe_key:='extra_charge:'||new.id::text||':approved:user'
      );
    end if;
  end if;

  if tg_op='UPDATE' and new.status='paid' and old.status is distinct from new.status then
    if nullif(trim(coalesce(target_reservation.contact_phone,customer_profile.phone,'')),'') is not null then
      perform public.enqueue_notification(
        target_event_key:='extra_charge_paid', target_template_key:='USER_EXTRA_CHARGE_PAID_V1',
        target_recipient_role:='user', target_recipient_user_id:=new.customer_id,
        target_recipient_name:=coalesce(target_reservation.customer_name,customer_profile.full_name,'이용자'),
        target_recipient_phone:=coalesce(target_reservation.contact_phone,customer_profile.phone),
        target_payload:=jsonb_build_object('숙소명',target_business.business_name,'추가금',public.notification_money(new.total_amount)),
        target_button_links:=jsonb_build_object('이용내역 보기',user_link),
        target_dedupe_key:='extra_charge:'||new.id::text||':paid:user'
      );
    end if;
    if nullif(trim(coalesce(owner_profile.phone,target_business.phone,'')),'') is not null then
      perform public.enqueue_notification(
        target_event_key:='extra_charge_paid', target_template_key:='OWNER_EXTRA_CHARGE_PAID_V1',
        target_recipient_role:='owner', target_recipient_user_id:=target_business.owner_id,
        target_recipient_name:=coalesce(owner_profile.full_name,target_business.representative_name,'사장님'),
        target_recipient_phone:=coalesce(owner_profile.phone,target_business.phone),
        target_payload:=jsonb_build_object('숙소명',target_business.business_name,'예약번호',new.reservation_id::text,'추가금',public.notification_money(new.total_amount)),
        target_button_links:=jsonb_build_object('예약 확인',owner_link),
        target_dedupe_key:='extra_charge:'||new.id::text||':paid:owner'
      );
    end if;
    perform public.enqueue_admin_notifications(
      p_event_key:='extra_charge_paid', p_template_key:='ADMIN_EXTRA_CHARGE_PAID_V1',
      p_payload:=jsonb_build_object('숙소명',target_business.business_name,'예약번호',new.reservation_id::text,'추가금',public.notification_money(new.total_amount)),
      p_button_links:=jsonb_build_object('결제 확인',owner_link),
      p_dedupe_prefix:='extra_charge:'||new.id::text||':paid:admin'
    );
  end if;

  if tg_op='UPDATE' and new.status='rejected' and old.status is distinct from new.status
     and nullif(trim(coalesce(owner_profile.phone,target_business.phone,'')),'') is not null then
    perform public.enqueue_notification(
      target_event_key:='extra_charge_rejected', target_template_key:='OWNER_EXTRA_CHARGE_REJECTED_V1',
      target_recipient_role:='owner', target_recipient_user_id:=target_business.owner_id,
      target_recipient_name:=coalesce(owner_profile.full_name,target_business.representative_name,'사장님'),
      target_recipient_phone:=coalesce(owner_profile.phone,target_business.phone),
      target_payload:=jsonb_build_object('숙소명',target_business.business_name,'예약번호',new.reservation_id::text,'추가금',public.notification_money(new.total_amount),'반려사유',coalesce(new.review_note,'운영팀 문의')),
      target_button_links:=jsonb_build_object('요청 확인',owner_link),
      target_dedupe_key:='extra_charge:'||new.id::text||':rejected:owner'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists notification_extra_charge_change on public.reservation_extra_charge_requests;
create trigger notification_extra_charge_change
after insert or update of status on public.reservation_extra_charge_requests
for each row execute function public.enqueue_extra_charge_notifications();

revoke all on function public.enqueue_extra_charge_notifications() from public;

comment on table public.customer_refund_accounts is 'Private refund destination used for KG Inicis virtual-account cancellations';
comment on table public.reservation_extra_charge_requests is 'Owner-submitted, admin-reviewed post-booking extra charges';
