-- Tighten direct table writes now that reservations, orders, payments, and chat
-- are handled through audited RPC functions or server routes.

-- Transaction records may be read through RLS, but status/payment changes should
-- go through set_reservation_status, set_market_order_status, PortOne webhooks,
-- or service-role server routes.
revoke insert, update, delete on public.reservations from authenticated;
revoke insert, update, delete on public.market_orders from authenticated;
revoke insert, update, delete on public.market_order_items from authenticated;
revoke insert, update, delete on public.payment_intents from authenticated;

grant select on public.reservations to authenticated;
grant select on public.market_orders to authenticated;
grant select on public.market_order_items to authenticated;
grant select on public.payment_intents to authenticated;

-- Chat writes should also go through the RPC functions so sender_role, message
-- length, participant checks, and read-receipt behavior cannot be bypassed.
revoke insert, update, delete on public.conversations from authenticated;
revoke insert, update, delete on public.messages from authenticated;

grant select on public.conversations to authenticated;
grant select on public.messages to authenticated;

drop policy if exists "conversations_user_insert" on public.conversations;
drop policy if exists "messages_participant_insert" on public.messages;

create or replace function public.start_business_conversation(
  target_business_id uuid,
  target_reservation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_id uuid;
  customer_profile public.profiles%rowtype;
  target_reservation public.reservations%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Login is required.';
  end if;

  select * into customer_profile
  from public.profiles
  where id = auth.uid()
    and role = 'user'
    and status = 'approved';

  if customer_profile.id is null then
    raise exception 'Only approved user accounts can start chats.';
  end if;

  if not exists (
    select 1
    from public.businesses
    where id = target_business_id
      and approval_status = 'approved'
  ) then
    raise exception 'Business is not available.';
  end if;

  if target_reservation_id is not null then
    select * into target_reservation
    from public.reservations
    where id = target_reservation_id;

    if target_reservation.id is null
      or target_reservation.customer_id is distinct from auth.uid()
      or target_reservation.business_id is distinct from target_business_id
    then
      raise exception 'Reservation does not belong to this chat.';
    end if;
  end if;

  select id into result_id
  from public.conversations
  where business_id = target_business_id
    and customer_id = auth.uid()
    and reservation_id is not distinct from target_reservation_id
  order by created_at desc
  limit 1;

  if result_id is null then
    insert into public.conversations (
      business_id,
      customer_id,
      reservation_id,
      customer_name,
      group_name
    ) values (
      target_business_id,
      auth.uid(),
      target_reservation_id,
      coalesce(nullif(customer_profile.full_name, ''), nullif(customer_profile.email, ''), 'User'),
      nullif(customer_profile.organization, '')
    )
    returning id into result_id;
  end if;

  return result_id;
end;
$$;

revoke all on function public.start_business_conversation(uuid, uuid) from public;
grant execute on function public.start_business_conversation(uuid, uuid) to authenticated;
