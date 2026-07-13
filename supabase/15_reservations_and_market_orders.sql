-- 실제 숙소 예약·공판장 주문 연결

alter table public.reservations
add column if not exists offering_id uuid references public.offerings(id) on delete set null,
add column if not exists request_memo text;

create table if not exists public.market_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  customer_name text not null,
  contact_phone text,
  pickup_place text not null,
  pickup_time time not null,
  request_memo text,
  total_amount integer not null default 0 check (total_amount >= 0),
  status text not null default 'pending'
    check (status in ('pending','confirmed','rejected','cancelled','completed')),
  reject_reason text,
  handled_by uuid references public.profiles(id) on delete set null,
  handled_by_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.market_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.market_orders(id) on delete cascade,
  offering_id uuid references public.offerings(id) on delete set null,
  item_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price integer not null check (unit_price >= 0),
  created_at timestamptz not null default now()
);

create index if not exists market_orders_business_status_idx
on public.market_orders(business_id, status);
create index if not exists market_orders_customer_idx
on public.market_orders(customer_id, created_at desc);
create index if not exists market_order_items_order_idx
on public.market_order_items(order_id);

create trigger market_orders_set_updated_at
before update on public.market_orders
for each row execute procedure public.set_updated_at();

alter table public.market_orders enable row level security;
alter table public.market_order_items enable row level security;

create policy "market_orders_read_participants"
on public.market_orders for select to authenticated
using (customer_id = auth.uid() or public.owns_business(business_id) or public.is_admin());

create policy "market_order_items_read_participants"
on public.market_order_items for select to authenticated
using (exists (
  select 1 from public.market_orders o
  where o.id = order_id
    and (o.customer_id = auth.uid() or public.owns_business(o.business_id) or public.is_admin())
));

grant select on public.market_orders, public.market_order_items to authenticated;
grant select, insert on public.reservations to authenticated;

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
  calculated_total integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '주문 상품이 없습니다.';
  end if;

  select coalesce(sum((item ->> 'quantity')::integer * (item ->> 'unit_price')::integer), 0)
  into calculated_total from jsonb_array_elements(items) item;

  insert into public.market_orders (
    business_id, customer_id, customer_name, contact_phone,
    pickup_place, pickup_time, request_memo, total_amount
  ) values (
    target_business_id, auth.uid(), customer_name, contact_phone,
    pickup_place, pickup_time, request_memo, calculated_total
  ) returning id into new_order_id;

  insert into public.market_order_items (
    order_id, offering_id, item_name, quantity, unit_price
  )
  select
    new_order_id,
    nullif(item ->> 'offering_id', '')::uuid,
    item ->> 'item_name',
    (item ->> 'quantity')::integer,
    (item ->> 'unit_price')::integer
  from jsonb_array_elements(items) item;

  return new_order_id;
end;
$$;

create or replace function public.set_market_order_status(
  target_order_id uuid,
  new_status text,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare target_business uuid;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception '올바르지 않은 주문 상태입니다.';
  end if;
  select business_id into target_business from public.market_orders where id = target_order_id;
  if target_business is null then raise exception '주문을 찾을 수 없습니다.'; end if;
  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception '주문 처리 권한이 없습니다.';
  end if;
  update public.market_orders
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      handled_by = auth.uid(), handled_by_admin = public.is_admin()
  where id = target_order_id;
end;
$$;

revoke all on function public.create_market_order(uuid,text,text,text,time,text,jsonb) from public;
revoke all on function public.set_market_order_status(uuid,text,text) from public;
grant execute on function public.create_market_order(uuid,text,text,text,time,text,jsonb) to authenticated;
grant execute on function public.set_market_order_status(uuid,text,text) to authenticated;
