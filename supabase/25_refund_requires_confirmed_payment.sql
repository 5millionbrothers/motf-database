-- Refund status guard.
-- Only prepaid requests with a confirmed payment_intent should become refund-required.
-- Legacy/test rows without a confirmed payment stay rejected without refund flags.

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
  target_current_status text;
  has_confirmed_payment boolean;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Invalid order status.';
  end if;

  select business_id, total_amount, status
  into target_business, target_amount, target_current_status
  from public.market_orders
  where id = target_order_id;

  if target_business is null then
    raise exception 'Order not found.';
  end if;

  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception 'You do not have permission to handle this order.';
  end if;

  if target_current_status in ('rejected', 'cancelled', 'completed') then
    raise exception 'Closed orders cannot be changed.';
  end if;

  select exists (
    select 1
    from public.payment_intents
    where kind = 'market'
      and transaction_id = target_order_id
      and status = 'confirmed'
      and payment_key is not null
  ) into has_confirmed_payment;

  update public.market_orders
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
        when new_status = 'rejected' and has_confirmed_payment then coalesce(nullif(reason, ''), 'Order rejected')
        when new_status = 'rejected' then null
        else refund_reason
      end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_order_id;

  if new_status = 'rejected' and has_confirmed_payment then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), 'Order rejected')
    where kind = 'market'
      and transaction_id = target_order_id
      and status = 'confirmed';
  end if;
end;
$$;

revoke all on function public.set_reservation_status(uuid, text, text) from public;
revoke all on function public.set_market_order_status(uuid, text, text) from public;
grant execute on function public.set_reservation_status(uuid, text, text) to authenticated;
grant execute on function public.set_market_order_status(uuid, text, text) to authenticated;
