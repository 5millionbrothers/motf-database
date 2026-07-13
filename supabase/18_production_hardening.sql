-- 운영 안정화: 공개 카탈로그 권한, 서버 가격 검증, 안정적인 상품 ID

-- 로그인한 이용자도 승인 업장의 공개 상품을 조회할 수 있어야 한다.
-- 07번의 기존 정책은 활성 상품이면 미승인 업장 상품도 허용하므로 교체한다.
drop policy if exists "offerings_read" on public.offerings;
drop policy if exists "offerings_owner_admin_read" on public.offerings;
create policy "offerings_owner_admin_read"
on public.offerings for select to authenticated
using (public.owns_business(business_id) or public.is_admin());

drop policy if exists "offerings_public_read_active" on public.offerings;
create policy "offerings_public_read_active"
on public.offerings for select to anon, authenticated
using (
  is_active
  and exists (
    select 1 from public.businesses b
    where b.id = business_id and b.approval_status = 'approved'
  )
);

grant select (
  id, business_id, name, description, price, is_active,
  max_people, unit, category, image_url, sort_order
) on public.offerings to authenticated;

-- 입력에 id가 있으면 수정하고, 없으면 새로 추가한다.
-- 목록에서 빠진 기존 상품만 삭제하여 유지되는 상품의 id가 바뀌지 않게 한다.
create or replace function public.save_business_offerings(
  target_business_id uuid,
  items jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.owns_business(target_business_id) and not public.is_admin() then
    raise exception '상품 수정 권한이 없습니다.';
  end if;

  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(items) item
    where nullif(trim(item ->> 'name'), '') is null
      or coalesce((item ->> 'price')::integer, -1) < 0
      or (nullif(item ->> 'max_people', '') is not null and (item ->> 'max_people')::integer <= 0)
  ) then
    raise exception '상품명, 가격 또는 최대 인원을 확인해주세요.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(items) item
    left join public.offerings o
      on o.id = nullif(item ->> 'id', '')::uuid
     and o.business_id = target_business_id
    where nullif(item ->> 'id', '') is not null and o.id is null
  ) then
    raise exception '다른 업장의 상품은 수정할 수 없습니다.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(items) item
    where nullif(item ->> 'id', '') is not null
    group by item ->> 'id'
    having count(*) > 1
  ) then
    raise exception '같은 상품이 두 번 포함되어 있습니다.';
  end if;

  delete from public.offerings o
  where o.business_id = target_business_id
    and not exists (
      select 1 from jsonb_array_elements(items) item
      where nullif(item ->> 'id', '')::uuid = o.id
    );

  update public.offerings o
  set name = nullif(trim(item ->> 'name'), ''),
      description = nullif(trim(item ->> 'description'), ''),
      price = (item ->> 'price')::integer,
      is_active = coalesce((item ->> 'is_active')::boolean, true),
      max_people = nullif(item ->> 'max_people', '')::integer,
      unit = nullif(trim(item ->> 'unit'), ''),
      category = nullif(trim(item ->> 'category'), ''),
      image_url = nullif(trim(item ->> 'image_url'), ''),
      sort_order = coalesce((item ->> 'sort_order')::integer, 0),
      updated_at = now()
  from jsonb_array_elements(items) item
  where o.id = nullif(item ->> 'id', '')::uuid
    and o.business_id = target_business_id;

  insert into public.offerings (
    business_id, name, description, price, is_active,
    max_people, unit, category, image_url, sort_order
  )
  select
    target_business_id,
    nullif(trim(item ->> 'name'), ''),
    nullif(trim(item ->> 'description'), ''),
    (item ->> 'price')::integer,
    coalesce((item ->> 'is_active')::boolean, true),
    nullif(item ->> 'max_people', '')::integer,
    nullif(trim(item ->> 'unit'), ''),
    nullif(trim(item ->> 'category'), ''),
    nullif(trim(item ->> 'image_url'), ''),
    coalesce((item ->> 'sort_order')::integer, 0)
  from jsonb_array_elements(items) item
  where nullif(item ->> 'id', '') is null;
end;
$$;

revoke all on function public.save_business_offerings(uuid, jsonb) from public;
grant execute on function public.save_business_offerings(uuid, jsonb) to authenticated;

-- 예약 금액과 상품명은 클라이언트가 아니라 DB의 상품 원본으로 확정한다.
create or replace function public.create_reservation(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  new_reservation_id uuid;
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
  join public.businesses b on b.id = o.business_id
  where o.id = target_offering_id
    and o.business_id = target_business_id
    and o.is_active
    and b.business_type = 'stay'
    and b.approval_status = 'approved';

  if selected_offering.id is null then raise exception '예약 가능한 객실을 찾을 수 없습니다.'; end if;
  if selected_offering.max_people is not null and guest_count > selected_offering.max_people then
    raise exception '선택한 객실의 최대 인원을 초과했습니다.';
  end if;

  insert into public.reservations (
    business_id, customer_id, offering_id, customer_name, group_name,
    contact_phone, event_date, guest_count, offering_name, total_amount, request_memo
  ) values (
    target_business_id, auth.uid(), selected_offering.id, trim(customer_name),
    nullif(trim(group_name), ''), nullif(trim(contact_phone), ''), event_date,
    guest_count, selected_offering.name, selected_offering.price, nullif(trim(request_memo), '')
  ) returning id into new_reservation_id;

  return new_reservation_id;
end;
$$;

revoke all on function public.create_reservation(uuid,uuid,text,text,text,date,integer,text) from public;
grant execute on function public.create_reservation(uuid,uuid,text,text,text,date,integer,text) to authenticated;

-- 주문 항목은 offering_id와 수량만 신뢰하고, 이름과 가격은 DB에서 읽는다.
create or replace function public.create_market_order(
  target_business_id uuid,
  customer_name text,
  contact_phone text,
  pickup_place text,
  pickup_time time,
  request_memo text,
  items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_order_id uuid;
  calculated_total bigint;
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

  if not exists (
    select 1 from public.businesses
    where id = target_business_id and business_type = 'market' and approval_status = 'approved'
  ) then raise exception '주문 가능한 공판장을 찾을 수 없습니다.'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
    left join public.offerings o
      on o.id = x.offering_id
     and o.business_id = target_business_id
     and o.is_active
    where x.offering_id is null or x.quantity is null or x.quantity <= 0 or x.quantity > 1000 or o.id is null
  ) then raise exception '판매 중인 상품과 수량을 확인해주세요.'; end if;

  select sum(o.price::bigint * x.quantity)
  into calculated_total
  from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
  join public.offerings o on o.id = x.offering_id and o.business_id = target_business_id and o.is_active;

  if calculated_total is null or calculated_total > 2147483647 then
    raise exception '주문 금액을 확인해주세요.';
  end if;

  insert into public.market_orders (
    business_id, customer_id, customer_name, contact_phone,
    pickup_place, pickup_time, request_memo, total_amount
  ) values (
    target_business_id, auth.uid(), trim(customer_name), nullif(trim(contact_phone), ''),
    trim(pickup_place), pickup_time, nullif(trim(request_memo), ''), calculated_total::integer
  ) returning id into new_order_id;

  insert into public.market_order_items (order_id, offering_id, item_name, quantity, unit_price)
  select new_order_id, o.id, o.name, sum(x.quantity)::integer, o.price
  from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
  join public.offerings o on o.id = x.offering_id and o.business_id = target_business_id and o.is_active
  group by o.id, o.name, o.price;

  return new_order_id;
end;
$$;

revoke all on function public.create_market_order(uuid,text,text,text,time,text,jsonb) from public;
grant execute on function public.create_market_order(uuid,text,text,text,time,text,jsonb) to authenticated;

-- 예약 생성은 위 검증 함수를 통해서만 허용한다.
revoke insert on public.reservations from authenticated;
drop policy if exists "reservations_user_insert" on public.reservations;
