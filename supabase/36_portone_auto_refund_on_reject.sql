-- Track PortOne refund/cancel requests triggered by owner/admin rejection.

alter table public.payment_intents
  add column if not exists refund_requested_at timestamptz,
  add column if not exists refund_response jsonb;

alter table public.reservations
  add column if not exists refund_requested_at timestamptz,
  add column if not exists refund_response jsonb;

alter table public.market_orders
  add column if not exists refund_requested_at timestamptz,
  add column if not exists refund_response jsonb;

grant select, update on public.payment_intents to service_role;
grant select, update on public.reservations to service_role;
grant select, update on public.market_orders to service_role;
