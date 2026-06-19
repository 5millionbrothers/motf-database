-- 적용 완료: 예약·채팅·상품 데이터 구조

create table public.offerings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  description text,
  price integer not null default 0 check (price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.profiles(id) on delete set null,
  customer_name text not null,
  group_name text,
  contact_phone text,
  event_date date not null,
  guest_count integer check (guest_count is null or guest_count > 0),
  offering_name text not null,
  total_amount integer not null default 0 check (total_amount >= 0),
  status text not null default 'pending'
    check (status in ('pending','confirmed','rejected','cancelled','completed')),
  reject_reason text,
  handled_by uuid references public.profiles(id) on delete set null,
  handled_by_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.profiles(id) on delete set null,
  reservation_id uuid references public.reservations(id) on delete set null,
  customer_name text not null,
  group_name text,
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  sender_role text not null check (sender_role in ('user','partner','admin')),
  body text not null check (char_length(body) between 1 and 4000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index reservations_business_date_idx on public.reservations(business_id, event_date);
create index reservations_business_status_idx on public.reservations(business_id, status);
create index conversations_business_last_idx on public.conversations(business_id, last_message_at desc);
create index messages_conversation_created_idx on public.messages(conversation_id, created_at);

create trigger offerings_set_updated_at before update on public.offerings
for each row execute procedure public.set_updated_at();
create trigger reservations_set_updated_at before update on public.reservations
for each row execute procedure public.set_updated_at();

create or replace function public.owns_business(target_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.businesses
    where id = target_business_id
      and owner_id = auth.uid()
      and approval_status = 'approved'
  );
$$;

grant execute on function public.owns_business(uuid) to authenticated;

alter table public.offerings enable row level security;
alter table public.reservations enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;

create policy "offerings_read" on public.offerings for select to authenticated
using (is_active or public.owns_business(business_id) or public.is_admin());
create policy "offerings_partner_insert" on public.offerings for insert to authenticated
with check (public.owns_business(business_id) or public.is_admin());
create policy "offerings_partner_update" on public.offerings for update to authenticated
using (public.owns_business(business_id) or public.is_admin())
with check (public.owns_business(business_id) or public.is_admin());

create policy "reservations_read" on public.reservations for select to authenticated
using (customer_id = auth.uid() or public.owns_business(business_id) or public.is_admin());
create policy "reservations_user_insert" on public.reservations for insert to authenticated
with check (customer_id = auth.uid());
create policy "reservations_partner_update" on public.reservations for update to authenticated
using (public.owns_business(business_id) or public.is_admin())
with check (public.owns_business(business_id) or public.is_admin());

create policy "conversations_read" on public.conversations for select to authenticated
using (customer_id = auth.uid() or public.owns_business(business_id) or public.is_admin());
create policy "conversations_user_insert" on public.conversations for insert to authenticated
with check (customer_id = auth.uid());

create policy "messages_read" on public.messages for select to authenticated
using (exists (
  select 1 from public.conversations c
  where c.id = conversation_id
    and (c.customer_id = auth.uid() or public.owns_business(c.business_id) or public.is_admin())
));
create policy "messages_participant_insert" on public.messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and exists (
    select 1 from public.conversations c
    where c.id = conversation_id
      and (c.customer_id = auth.uid() or public.owns_business(c.business_id) or public.is_admin())
  )
);

grant select, insert, update on public.offerings to authenticated;
grant select, insert, update on public.reservations to authenticated;
grant select, insert, update on public.conversations to authenticated;
grant select, insert on public.messages to authenticated;

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
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception '올바르지 않은 예약 상태입니다.';
  end if;

  select business_id into target_business
  from public.reservations where id = target_reservation_id;

  if target_business is null then
    raise exception '예약을 찾을 수 없습니다.';
  end if;

  if not public.owns_business(target_business) and not public.is_admin() then
    raise exception '예약 처리 권한이 없습니다.';
  end if;

  update public.reservations
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_reservation_id;
end;
$$;

revoke all on function public.set_reservation_status(uuid, text, text) from public;
grant execute on function public.set_reservation_status(uuid, text, text) to authenticated;
