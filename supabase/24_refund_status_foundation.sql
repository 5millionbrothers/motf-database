-- Refund status foundation for the prepaid request flow.
-- Actual Toss cancel API calls will be added in the application server later.

alter table public.reservations
  add column if not exists payment_status text not null default 'paid'
    check (payment_status in ('paid', 'refund_required', 'refund_processing', 'refunded', 'refund_failed')),
  add column if not exists refund_status text not null default 'none'
    check (refund_status in ('none', 'required', 'processing', 'refunded', 'failed')),
  add column if not exists refund_amount integer check (refund_amount is null or refund_amount >= 0),
  add column if not exists refund_reason text,
  add column if not exists refunded_at timestamptz;

alter table public.market_orders
  add column if not exists payment_status text not null default 'paid'
    check (payment_status in ('paid', 'refund_required', 'refund_processing', 'refunded', 'refund_failed')),
  add column if not exists refund_status text not null default 'none'
    check (refund_status in ('none', 'required', 'processing', 'refunded', 'failed')),
  add column if not exists refund_amount integer check (refund_amount is null or refund_amount >= 0),
  add column if not exists refund_reason text,
  add column if not exists refunded_at timestamptz;

alter table public.payment_intents
  add column if not exists refund_status text not null default 'none'
    check (refund_status in ('none', 'required', 'processing', 'refunded', 'failed')),
  add column if not exists refund_amount integer check (refund_amount is null or refund_amount >= 0),
  add column if not exists refund_reason text,
  add column if not exists refunded_at timestamptz;

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
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception '올바르지 않은 예약 상태입니다.';
  end if;

  select business_id, total_amount
  into target_business, target_amount
  from public.reservations
  where id = target_reservation_id;

  if target_business is null then
    raise exception '예약을 찾을 수 없습니다.';
  end if;

  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception '예약 처리 권한이 없습니다.';
  end if;

  update public.reservations
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      payment_status = case when new_status = 'rejected' then 'refund_required' else payment_status end,
      refund_status = case when new_status = 'rejected' then 'required' else refund_status end,
      refund_amount = case when new_status = 'rejected' then total_amount else refund_amount end,
      refund_reason = case when new_status = 'rejected' then coalesce(nullif(reason, ''), '예약 요청 거절') else refund_reason end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_reservation_id;

  if new_status = 'rejected' then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), '예약 요청 거절')
    where kind = 'stay'
      and transaction_id = target_reservation_id;
  end if;
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
declare
  target_business uuid;
  target_amount integer;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception '올바르지 않은 주문 상태입니다.';
  end if;

  select business_id, total_amount
  into target_business, target_amount
  from public.market_orders
  where id = target_order_id;

  if target_business is null then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception '주문 처리 권한이 없습니다.';
  end if;

  update public.market_orders
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      payment_status = case when new_status = 'rejected' then 'refund_required' else payment_status end,
      refund_status = case when new_status = 'rejected' then 'required' else refund_status end,
      refund_amount = case when new_status = 'rejected' then total_amount else refund_amount end,
      refund_reason = case when new_status = 'rejected' then coalesce(nullif(reason, ''), '주문 요청 거절') else refund_reason end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_order_id;

  if new_status = 'rejected' then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), '주문 요청 거절')
    where kind = 'market'
      and transaction_id = target_order_id;
  end if;
end;
$$;

revoke all on function public.set_reservation_status(uuid, text, text) from public;
revoke all on function public.set_market_order_status(uuid, text, text) from public;
grant execute on function public.set_reservation_status(uuid, text, text) to authenticated;
grant execute on function public.set_market_order_status(uuid, text, text) to authenticated;

comment on column public.reservations.refund_status is 'Refund workflow state. required means a Toss cancel API call is needed.';
comment on column public.market_orders.refund_status is 'Refund workflow state. required means a Toss cancel API call is needed.';
comment on column public.payment_intents.refund_status is 'Refund workflow state for the original Toss payment.';
