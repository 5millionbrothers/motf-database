-- Archived rollback helper. Do not run during normal migration setup.
-- Optional rollback only if 29B_virtual_account_display_fix.sql was successfully executed.
-- This restores mark_virtual_account_issued to the pre-29 PortOne virtual-account behavior.

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
begin
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

  update public.payment_intents
  set status = 'virtual_account_issued',
      provider = 'portone',
      pg_provider = coalesce(portone_response ->> 'pgProvider', portone_response ->> 'pg_provider', pg_provider),
      channel_key = coalesce(portone_response ->> 'channelKey', portone_response ->> 'channel_key', channel_key),
      virtual_account = coalesce(portone_response -> 'virtualAccount', portone_response -> 'virtual_account', portone_response -> 'virtualAccountIssued'),
      payment_response = portone_response,
      virtual_account_issued_at = coalesce(virtual_account_issued_at, now())
  where id = intent.id
  returning payment_intents.order_id, payment_intents.status, payment_intents.virtual_account
  into order_id, status, virtual_account;

  return next;
end;
$$;

revoke all on function public.mark_virtual_account_issued(uuid, text, jsonb) from public;
grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to service_role;
