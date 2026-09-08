-- Admin content controls and deterministic checkout-hold cleanup.

alter table public.homepage_cards
  add column if not exists home_slot smallint;

alter table public.homepage_cards
  drop constraint if exists homepage_cards_home_slot_check;
alter table public.homepage_cards
  add constraint homepage_cards_home_slot_check
  check (home_slot is null or home_slot between 1 and 3);

create index if not exists homepage_cards_home_slot_idx
on public.homepage_cards(home_slot, sort_order)
where is_active = true and placement = 'hero';

alter table public.recreation_activities
  add column if not exists example_video_url text,
  add column if not exists script_file_url text;

grant select on public.homepage_cards, public.recreation_activities to anon, authenticated;
grant insert, update, delete on public.homepage_cards, public.recreation_activities to authenticated;

create or replace function public.release_expired_checkout_intents()
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer;
begin
  update public.payment_intents
  set status = 'expired', updated_at = now()
  where status in ('prepared','ready','in_progress')
    and expires_at <= now();
  get diagnostics affected = row_count;

  update public.point_holds h set status='released', released_at=now()
  from public.payment_intents pi
  where h.payment_intent_id=pi.id and h.status='held'
    and (pi.status in ('expired','failed','cancelled','aborted') or pi.expires_at<=now());

  update public.coupon_redemptions r set status='released'
  from public.payment_intents pi
  where r.payment_intent_id=pi.id and r.status='reserved'
    and (pi.status in ('expired','failed','cancelled','aborted') or pi.expires_at<=now());

  update public.market_inventory_holds h set status='released'
  from public.payment_intents pi
  where h.payment_intent_id=pi.id and h.status='held'
    and (pi.status in ('expired','failed','cancelled','aborted') or pi.expires_at<=now());

  update public.stay_availability_blocks b
  set status='cancelled',
      note=trim(both ' ' from coalesce(b.note,'') || ' / checkout expired'),
      updated_at=now()
  from public.payment_intents pi
  where b.payment_intent_id=pi.id
    and b.source='checkout_hold'
    and b.status='active'
    and (pi.status in ('expired','failed','cancelled','aborted') or pi.expires_at<=now());

  return affected;
end;
$$;

revoke all on function public.release_expired_checkout_intents() from public;
grant execute on function public.release_expired_checkout_intents() to anon, authenticated, service_role;
