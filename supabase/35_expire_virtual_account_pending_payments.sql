-- Expire unpaid virtual-account payment intents and release their room blocks.
-- We keep the payment_intents row for audit/history, but hide it from active
-- pending lists by moving it to status = 'expired'.

create or replace function public.release_expired_pending_stay_blocks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  released_count integer := 0;
  expired_count integer := 0;
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

  update public.payment_intents pi
  set status = 'expired',
      updated_at = now()
  where pi.status = 'virtual_account_issued'
    and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') <= now();

  get diagnostics expired_count = row_count;
  return released_count + expired_count;
end;
$$;

grant execute on function public.release_expired_pending_stay_blocks() to authenticated, service_role;
