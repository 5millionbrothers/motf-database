-- Launch review hardening: identity signup, coupon archival and event favorites.

create or replace function public.complete_identity_signup_profile(
  target_user_id uuid,
  target_email text,
  target_full_name text,
  target_phone text,
  target_birth_date date,
  target_ci_hash text,
  target_verified_at timestamptz,
  target_is_adult boolean,
  target_account_type text default 'user'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (
    id, email, full_name, phone, birth_date, role, status,
    identity_provider, identity_ci_hash, identity_verified_at,
    adult_verified_at, password_set_at
  )
  values (
    target_user_id,
    lower(trim(target_email)),
    nullif(trim(target_full_name), ''),
    nullif(regexp_replace(target_phone, '[^0-9]', '', 'g'), ''),
    target_birth_date,
    case when target_account_type = 'partner' then 'partner' else 'user' end,
    case when target_account_type = 'partner' then 'pending' else 'approved' end,
    'kcp',
    target_ci_hash,
    target_verified_at,
    case when target_is_adult then target_verified_at else null end,
    now()
  )
  on conflict (id) do update
  set email = excluded.email,
      full_name = excluded.full_name,
      phone = excluded.phone,
      birth_date = excluded.birth_date,
      role = excluded.role,
      status = excluded.status,
      identity_provider = excluded.identity_provider,
      identity_ci_hash = excluded.identity_ci_hash,
      identity_verified_at = excluded.identity_verified_at,
      adult_verified_at = excluded.adult_verified_at,
      password_set_at = coalesce(public.profiles.password_set_at, excluded.password_set_at),
      updated_at = now();
end;
$$;

revoke all on function public.complete_identity_signup_profile(uuid,text,text,text,date,text,timestamptz,boolean,text) from public;
grant execute on function public.complete_identity_signup_profile(uuid,text,text,text,date,text,timestamptz,boolean,text) to service_role;

-- Repair accounts that received an email but missed the profile update during signup.
with latest_verification as (
  select distinct on (lower(s.requested_email))
    lower(s.requested_email) as email,
    s.verified_name,
    s.verified_phone,
    s.verified_birth_date,
    s.verified_ci_hash,
    s.verified_at,
    s.is_adult
  from public.identity_verification_sessions s
  where s.status in ('verified', 'consumed')
    and s.purpose in ('signup', 'owner_signup')
    and s.requested_email is not null
    and s.verified_ci_hash is not null
  order by lower(s.requested_email), s.verified_at desc nulls last, s.created_at desc
)
update public.profiles p
set full_name = coalesce(nullif(p.full_name, ''), v.verified_name),
    phone = coalesce(nullif(p.phone, ''), v.verified_phone),
    birth_date = coalesce(p.birth_date, v.verified_birth_date),
    identity_provider = 'kcp',
    identity_ci_hash = coalesce(p.identity_ci_hash, v.verified_ci_hash),
    identity_verified_at = coalesce(p.identity_verified_at, v.verified_at),
    adult_verified_at = case
      when p.adult_verified_at is not null then p.adult_verified_at
      when v.is_adult then v.verified_at
      else null
    end,
    updated_at = now()
from auth.users u
join latest_verification v on v.email = lower(u.email)
where p.id = u.id
  and p.identity_verified_at is null;

create or replace function public.admin_archive_coupon(target_coupon_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  redemption_count integer;
begin
  if not public.is_admin() then
    raise exception '운영자 권한이 필요합니다.';
  end if;

  select count(*) into redemption_count
  from public.coupon_redemptions
  where coupon_id = target_coupon_id;

  if redemption_count > 0 then
    update public.coupons
    set is_active = false,
        updated_at = now()
    where id = target_coupon_id;
    return 'archived';
  end if;

  delete from public.coupons where id = target_coupon_id;
  return 'deleted';
end;
$$;

revoke all on function public.admin_archive_coupon(uuid) from public;
grant execute on function public.admin_archive_coupon(uuid) to authenticated;

create table if not exists public.user_favorite_events (
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_id uuid not null references public.platform_events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

alter table public.user_favorite_events enable row level security;
drop policy if exists "favorite_events_owner_read" on public.user_favorite_events;
create policy "favorite_events_owner_read" on public.user_favorite_events
for select to authenticated using (user_id = auth.uid());
drop policy if exists "favorite_events_owner_insert" on public.user_favorite_events;
create policy "favorite_events_owner_insert" on public.user_favorite_events
for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "favorite_events_owner_delete" on public.user_favorite_events;
create policy "favorite_events_owner_delete" on public.user_favorite_events
for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.user_favorite_events to authenticated;

comment on function public.complete_identity_signup_profile(uuid,text,text,text,date,text,timestamptz,boolean,text)
is 'Service-only atomic profile completion after KCP verification and Supabase Auth signup';
comment on function public.admin_archive_coupon(uuid)
is 'Deletes unused coupons and archives coupons referenced by redemption history';
