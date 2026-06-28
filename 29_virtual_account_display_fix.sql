-- Make PortOne virtual-account issuance visible to users/admins.
-- Some PortOne V2 responses place account details under paymentMethod instead of virtualAccount.

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
  account_payload jsonb;
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

  account_payload := coalesce(
    portone_response -> 'virtualAccount',
    portone_response -> 'virtual_account',
    portone_response -> 'virtualAccountIssued',
    portone_response -> 'virtual_account_issued',
    case
      when portone_response #>> '{paymentMethod,type}' = 'VIRTUAL_ACCOUNT'
      then portone_response -> 'paymentMethod'
      else null
    end,
    case
      when portone_response #>> '{payment_method,type}' = 'VIRTUAL_ACCOUNT'
      then portone_response -> 'payment_method'
      else null
    end,
    case
      when portone_response #>> '{paymentMethodDetail,type}' = 'VIRTUAL_ACCOUNT'
      then portone_response -> 'paymentMethodDetail'
      else null
    end,
    case
      when portone_response #>> '{payment_method_detail,type}' = 'VIRTUAL_ACCOUNT'
      then portone_response -> 'payment_method_detail'
      else null
    end,
    '{}'::jsonb
  );

  update public.payment_intents
  set status = 'virtual_account_issued',
      provider = 'portone',
      pg_provider = coalesce(portone_response ->> 'pgProvider', portone_response ->> 'pg_provider', pg_provider),
      channel_key = coalesce(portone_response ->> 'channelKey', portone_response ->> 'channel_key', channel_key),
      virtual_account = account_payload,
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
