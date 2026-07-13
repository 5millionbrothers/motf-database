-- Use the same short order id in moTF DB and PortOne paymentId.
-- New IDs stay below common PG limits:
--   stay   MS-YYYYMMDD-XXXXXXXXXXXX
--   market MM-YYYYMMDD-XXXXXXXXXXXX

create or replace function public.prepare_stay_payment(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null,
  check_in_date date default null,
  check_out_date date default null
)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  selected_business public.businesses%rowtype;
  new_order_id text;
  actual_check_in date := coalesce(check_in_date, event_date);
  actual_check_out date := coalesce(check_out_date, event_date + 1);
begin
  if auth.uid() is null then raise exception 'Login is required.'; end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'user' and status = 'approved'
  ) then raise exception 'This account cannot create reservations.'; end if;
  if nullif(trim(customer_name), '') is null then raise exception 'Customer name is required.'; end if;
  if actual_check_in < current_date then raise exception 'Past dates cannot be reserved.'; end if;
  if actual_check_in >= actual_check_out then raise exception 'Invalid stay date range.'; end if;
  if guest_count is null or guest_count <= 0 then raise exception 'Guest count is required.'; end if;

  select o.* into selected_offering
  from public.offerings o
  where o.id = target_offering_id and o.business_id = target_business_id and o.is_active;

  select b.* into selected_business
  from public.businesses b
  where b.id = target_business_id and b.business_type = 'stay' and b.approval_status = 'approved';

  if selected_offering.id is null or selected_business.id is null then
    raise exception 'Reservable room was not found.';
  end if;
  if selected_offering.max_people is not null and guest_count > selected_offering.max_people then
    raise exception 'Guest count exceeds room capacity.';
  end if;
  if selected_offering.price <= 0 then raise exception 'Invalid payment amount.'; end if;
  if not public.stay_range_is_available(selected_offering.id, actual_check_in, actual_check_out) then
    raise exception 'This room is already blocked for the selected dates.';
  end if;

  loop
    new_order_id := 'MS-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (
      select 1 from public.payment_intents pi where pi.order_id = new_order_id
    );
  end loop;

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
      'event_date', actual_check_in,
      'check_in_date', actual_check_in,
      'check_out_date', actual_check_out,
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
  new_order_id text;
  new_order_name text;
begin
  if auth.uid() is null then raise exception 'Login is required.'; end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'user' and status = 'approved'
  ) then raise exception 'This account cannot create orders.'; end if;
  if nullif(trim(customer_name), '') is null or nullif(trim(pickup_place), '') is null then
    raise exception 'Customer name and pickup place are required.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'Order items are required.';
  end if;

  select b.* into selected_business
  from public.businesses b
  where b.id = target_business_id and b.business_type = 'market' and b.approval_status = 'approved';
  if selected_business.id is null then raise exception 'Orderable market was not found.'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(items) as x(offering_id uuid, quantity integer)
    left join public.offerings o
      on o.id = x.offering_id and o.business_id = target_business_id and o.is_active
    where x.offering_id is null or x.quantity is null or x.quantity <= 0 or x.quantity > 1000 or o.id is null
  ) then raise exception 'Please check orderable items and quantities.'; end if;

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
    raise exception 'Invalid order amount.';
  end if;
  new_order_name := left(selected_business.business_name || ' ' || first_item_name || case when item_count > 1 then ' plus ' || (item_count - 1) || ' items' else '' end, 100);

  loop
    new_order_id := 'MM-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (
      select 1 from public.payment_intents pi where pi.order_id = new_order_id
    );
  end loop;

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

revoke all on function public.prepare_stay_payment(uuid, uuid, text, text, text, date, integer, text, date, date) from public;
revoke all on function public.prepare_market_payment(uuid, text, text, text, time, text, jsonb) from public;
grant execute on function public.prepare_stay_payment(uuid, uuid, text, text, text, date, integer, text, date, date) to authenticated;
grant execute on function public.prepare_market_payment(uuid, text, text, text, time, text, jsonb) to authenticated;
