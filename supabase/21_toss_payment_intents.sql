-- moTF 3/10: 토스페이먼츠 결제 원장과 승인 후 거래 생성

create table if not exists public.payment_intents (
  id uuid primary key default gen_random_uuid(),
  order_id text not null unique,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('stay', 'market')),
  amount integer not null check (amount > 0),
  order_name text not null,
  draft jsonb not null,
  status text not null default 'prepared'
    check (status in ('prepared', 'confirmed', 'failed', 'expired')),
  payment_key text unique,
  transaction_id uuid,
  toss_response jsonb,
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payment_intents_customer_created_idx
on public.payment_intents(customer_id, created_at desc);

create trigger payment_intents_set_updated_at
before update on public.payment_intents
for each row execute procedure public.set_updated_at();

alter table public.payment_intents enable row level security;

create policy "payment_intents_read_owner_or_admin"
on public.payment_intents for select to authenticated
using (customer_id = auth.uid() or public.is_admin());

grant select on public.payment_intents to authenticated;

create or replace function public.prepare_stay_payment(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null
)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  selected_business public.businesses%rowtype;
  new_order_id text := 'MOTF-STAY-' || replace(gen_random_uuid()::text, '-', '');
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'user' and status = 'approved'
  ) then raise exception '이용 가능한 일반 회원 계정이 아닙니다.'; end if;
  if nullif(trim(customer_name), '') is null then raise exception '대표자 이름을 입력해주세요.'; end if;
  if event_date < current_date then raise exception '지난 날짜는 예약할 수 없습니다.'; end if;
  if guest_count is null or guest_count <= 0 then raise exception '인원을 확인해주세요.'; end if;

  select o.* into selected_offering
  from public.offerings o
  where o.id = target_offering_id and o.business_id = target_business_id and o.is_active;

  select b.* into selected_business
  from public.businesses b
  where b.id = target_business_id and b.business_type = 'stay' and b.approval_status = 'approved';

  if selected_offering.id is null or selected_business.id is null then
    raise exception '예약 가능한 객실을 찾을 수 없습니다.';
  end if;
  if selected_offering.max_people is not null and guest_count > selected_offering.max_people then
    raise exception '선택한 객실의 최대 인원을 초과했습니다.';
  end if;
  if selected_offering.price <= 0 then raise exception '결제 금액을 확인해주세요.'; end if;

  insert into public.payment_intents (
    order_id, customer_id, kind, amount, order_name, draft
  ) values (
    new_order_id,
    auth.uid(),
    'stay',
    selected_offering.price,
    left(selected_business.business_name || ' ' || selected_offering.name, 100),
    jsonb_build_object(
      'business_id', selected_business.id,
      'offering_id', selected_offering.id,
      'offering_name', selected_offering.name,
      'customer_name', trim(customer_name),
      'group_name', nullif(trim(group_name), ''),
      'contact_phone', nullif(trim(contact_phone), ''),
      'event_date', event_date,
      'guest_count', guest_count,
      'request_memo', nullif(trim(request_memo), '')
    )
  );

  return query select new_order_id, selected_offering.price, left(selected_business.business_name || ' ' || selected_offering.name, 100), 'stay'::text;
end;
$$;

create or replace function public.prepare_market_payment(
  target_business_id uuid,
  customer_name text,
  contact_phone text,
  pickup_place text,
  pickup_time time,
  request_memo text,
  items jsonb
)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_business public.businesses%rowtype;
  snapshot_items jsonb;
  calculated_total bigint;
  item_count integer;
  first_item_name text;
  new_order_id text := 'MOTF-MARKET-' || replace(gen_random_uuid()::text, '-', '');
  new_order_name text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'user' and status = 'approved'
  ) then raise exception '이용 가능한 일반 회원 계정이 아닙니다.'; end if;
  if nullif(trim(customer_name), '') is null or nullif(trim(pickup_place), '') is null then
    raise exception '주문자와 수령 장소를 입력해주세요.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '주문 상품이 없습니다.';
  end if;

  select b.* into selected_business
  from public.businesses b
  where b.id = target_business_id and b.business_type = 'market' and b.approval_status = 'approved';
  if selected_business.id is null then raise exception '주문 가능한 공판장을 찾을 수 없습니다.'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
    left join public.offerings o
      on o.id = x.offering_id and o.business_id = target_business_id and o.is_active
    where x.offering_id is null or x.quantity is null or x.quantity <= 0 or x.quantity > 1000 or o.id is null
  ) then raise exception '판매 중인 상품과 수량을 확인해주세요.'; end if;

  select
    jsonb_agg(jsonb_build_object(
      'offering_id', grouped.offering_id,
      'item_name', grouped.item_name,
      'quantity', grouped.quantity,
      'unit_price', grouped.unit_price
    ) order by grouped.item_name),
    sum(grouped.unit_price::bigint * grouped.quantity),
    count(*),
    min(grouped.item_name)
  into snapshot_items, calculated_total, item_count, first_item_name
  from (
    select o.id as offering_id, o.name as item_name, sum(x.quantity)::integer as quantity, o.price as unit_price
    from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
    join public.offerings o
      on o.id = x.offering_id and o.business_id = target_business_id and o.is_active
    group by o.id, o.name, o.price
  ) grouped;

  if calculated_total is null or calculated_total <= 0 or calculated_total > 2147483647 then
    raise exception '주문 금액을 확인해주세요.';
  end if;
  new_order_name := left(selected_business.business_name || ' ' || first_item_name || case when item_count > 1 then ' 외 ' || (item_count - 1) || '개' else '' end, 100);

  insert into public.payment_intents (
    order_id, customer_id, kind, amount, order_name, draft
  ) values (
    new_order_id,
    auth.uid(),
    'market',
    calculated_total::integer,
    new_order_name,
    jsonb_build_object(
      'business_id', selected_business.id,
      'customer_name', trim(customer_name),
      'contact_phone', nullif(trim(contact_phone), ''),
      'pickup_place', trim(pickup_place),
      'pickup_time', pickup_time,
      'request_memo', nullif(trim(request_memo), ''),
      'items', snapshot_items
    )
  );

  return query select new_order_id, calculated_total::integer, new_order_name, 'market'::text;
end;
$$;

create or replace function public.finalize_payment_intent(
  target_customer_id uuid,
  target_order_id text,
  target_payment_key text,
  payment_response jsonb
)
returns table(transaction_id uuid, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent public.payment_intents%rowtype;
  new_transaction_id uuid;
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
  if intent.status <> 'prepared' then raise exception '처리할 수 없는 결제 상태입니다.'; end if;
  if (payment_response ->> 'orderId') is distinct from intent.order_id
     or (payment_response ->> 'paymentKey') is distinct from target_payment_key
     or coalesce((payment_response ->> 'totalAmount')::integer, -1) <> intent.amount
     or (payment_response ->> 'status') is distinct from 'DONE' then
    raise exception '토스 승인 정보가 결제 대기 내역과 일치하지 않습니다.';
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
      toss_response = payment_response,
      confirmed_at = now()
  where id = intent.id;

  return query select new_transaction_id, intent.kind;
end;
$$;

revoke all on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text) from public;
revoke all on function public.prepare_market_payment(uuid,text,text,text,time,text,jsonb) from public;
revoke all on function public.finalize_payment_intent(uuid,text,text,jsonb) from public;
grant execute on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text) to authenticated;
grant execute on function public.prepare_market_payment(uuid,text,text,text,time,text,jsonb) to authenticated;
grant execute on function public.finalize_payment_intent(uuid,text,text,jsonb) to service_role;
