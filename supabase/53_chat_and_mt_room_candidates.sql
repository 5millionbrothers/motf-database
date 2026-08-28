-- Keep one customer chat per business and make My MT lodging candidates room-based.

-- Merge conversations that were split by reservation_id before adding the guard.
with ranked as (
  select
    id,
    first_value(id) over (
      partition by customer_id, business_id
      order by created_at, id
    ) as keep_id,
    row_number() over (
      partition by customer_id, business_id
      order by created_at, id
    ) as row_no
  from public.conversations
  where customer_id is not null
), duplicates as (
  select id, keep_id from ranked where row_no > 1
)
update public.messages m
set conversation_id = d.keep_id
from duplicates d
where m.conversation_id = d.id;

with ranked as (
  select
    id,
    row_number() over (
      partition by customer_id, business_id
      order by created_at, id
    ) as row_no
  from public.conversations
  where customer_id is not null
)
delete from public.conversations c
using ranked r
where c.id = r.id and r.row_no > 1;

update public.conversations c
set last_message_at = coalesce((
  select max(m.created_at) from public.messages m where m.conversation_id = c.id
), c.last_message_at);

create unique index if not exists conversations_customer_business_unique
on public.conversations(customer_id, business_id)
where customer_id is not null;

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
  where id = auth.uid() and role = 'user' and status = 'approved';

  if customer_profile.id is null then
    raise exception 'Only approved user accounts can start chats.';
  end if;

  if not exists (
    select 1 from public.businesses
    where id = target_business_id and approval_status = 'approved'
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

  perform pg_advisory_xact_lock(
    hashtextextended(auth.uid()::text || ':' || target_business_id::text, 0)
  );

  select id into result_id
  from public.conversations
  where business_id = target_business_id and customer_id = auth.uid()
  order by created_at
  limit 1;

  if result_id is null then
    insert into public.conversations (
      business_id, customer_id, reservation_id, customer_name, group_name
    ) values (
      target_business_id,
      auth.uid(),
      target_reservation_id,
      coalesce(nullif(customer_profile.full_name, ''), nullif(customer_profile.email, ''), 'User'),
      nullif(customer_profile.organization, '')
    )
    returning id into result_id;
  elsif target_reservation_id is not null then
    update public.conversations
    set reservation_id = coalesce(reservation_id, target_reservation_id)
    where id = result_id;
  end if;

  return result_id;
end;
$$;

revoke all on function public.start_business_conversation(uuid, uuid) from public;
grant execute on function public.start_business_conversation(uuid, uuid) to authenticated;

-- Convert legacy business-only candidates to a concrete active room.
alter table public.mt_project_candidates
drop constraint if exists mt_project_candidates_project_id_business_id_key;

update public.mt_project_candidates c
set offering_id = (
  select o.id
  from public.offerings o
  where o.business_id = c.business_id and o.is_active
  order by o.sort_order, o.created_at, o.id
  limit 1
)
where c.offering_id is null;

delete from public.mt_project_candidates where offering_id is null;

with ranked as (
  select
    id,
    row_number() over (
      partition by project_id, offering_id
      order by created_at, id
    ) as row_no
  from public.mt_project_candidates
)
delete from public.mt_project_candidates c
using ranked r
where c.id = r.id and r.row_no > 1;

alter table public.mt_project_candidates
alter column offering_id set not null;

alter table public.mt_project_candidates
drop constraint if exists mt_project_candidates_offering_id_fkey;
alter table public.mt_project_candidates
add constraint mt_project_candidates_offering_id_fkey
foreign key (offering_id) references public.offerings(id) on delete cascade;

create unique index if not exists mt_candidates_project_offering_unique
on public.mt_project_candidates(project_id, offering_id);

update public.mt_project_items i
set reference_id = (
  select candidate.offering_id
  from public.mt_project_candidates candidate
  where candidate.project_id = i.project_id
    and candidate.business_id = i.reference_id
  order by candidate.sort_order, candidate.created_at
  limit 1
)
where i.item_kind = 'stay'
  and i.reference_id is not null
  and exists (
    select 1 from public.mt_project_candidates candidate
    where candidate.project_id = i.project_id
      and candidate.business_id = i.reference_id
  );

create or replace function public.save_mt_room_candidate(
  target_project_id uuid,
  target_business_id uuid,
  target_offering_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_project public.mt_projects%rowtype;
  target_room public.offerings%rowtype;
  candidate_id uuid;
  base_amount integer;
  extra_people integer;
  extra_people_amount integer;
begin
  if auth.uid() is null then
    raise exception 'Login is required.';
  end if;

  select * into target_project
  from public.mt_projects
  where id = target_project_id
    and (owner_id = auth.uid() or public.is_admin());

  if target_project.id is null then
    raise exception 'My MT project was not found.';
  end if;

  select * into target_room
  from public.offerings
  where id = target_offering_id
    and business_id = target_business_id
    and is_active;

  if target_room.id is null then
    raise exception 'The selected room is not available.';
  end if;

  if not public.stay_range_is_available(
    target_room.id,
    target_project.starts_on,
    target_project.ends_on
  ) then
    raise exception 'The selected room is already booked for the My MT dates.';
  end if;

  if not exists (
    select 1 from public.mt_project_candidates c
    where c.project_id = target_project.id and c.offering_id = target_room.id
  ) and (
    select count(*) from public.mt_project_candidates c
    where c.project_id = target_project.id
  ) >= 3 then
    raise exception 'Up to three room candidates can be saved per My MT project.';
  end if;

  base_amount := public.calculate_stay_base_amount(
    target_room.id,
    target_project.starts_on,
    target_project.ends_on
  );
  extra_people := greatest(
    target_project.guest_count - coalesce(target_room.base_people, target_room.min_people, 0),
    0
  );
  extra_people_amount := extra_people * coalesce(target_room.extra_person_fee, 0);

  insert into public.mt_project_candidates (
    project_id, business_id, offering_id, estimated_cost, sort_order
  ) values (
    target_project.id,
    target_business_id,
    target_room.id,
    jsonb_build_object(
      'room_total', base_amount,
      'confirmed', base_amount,
      'extra_people', extra_people,
      'extra_person_total', extra_people_amount,
      'optional', 0,
      'on_site', extra_people_amount,
      'total', base_amount + extra_people_amount,
      'room_names', jsonb_build_array(target_room.name)
    ),
    (extract(epoch from clock_timestamp())::bigint % 1000000)::integer
  )
  on conflict (project_id, offering_id) do update
  set
    business_id = excluded.business_id,
    estimated_cost = excluded.estimated_cost,
    sort_order = excluded.sort_order
  returning id into candidate_id;

  return candidate_id;
end;
$$;

revoke all on function public.save_mt_room_candidate(uuid, uuid, uuid) from public;
grant execute on function public.save_mt_room_candidate(uuid, uuid, uuid) to authenticated;

comment on function public.save_mt_room_candidate(uuid, uuid, uuid)
is 'Adds one currently available room, rather than a whole business, to a user My MT project';
