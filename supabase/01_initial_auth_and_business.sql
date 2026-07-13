-- 적용 완료: 회원 프로필, 업장 정보, 가입 트리거 및 기본 보안 정책

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  username text unique,
  full_name text,
  phone text,
  role text not null default 'partner'
    check (role in ('user', 'partner', 'admin')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  business_type text not null check (business_type in ('stay', 'market')),
  business_name text not null,
  representative_name text not null,
  phone text,
  business_number text,
  address text,
  description text,
  approval_status text not null default 'pending'
    check (approval_status in ('pending', 'approved', 'rejected', 'suspended')),
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, phone, role, status)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'phone',
    'partner',
    'pending'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at before update on public.profiles
for each row execute procedure public.set_updated_at();

create trigger businesses_set_updated_at before update on public.businesses
for each row execute procedure public.set_updated_at();

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'approved'
  );
$$;

grant execute on function public.is_admin() to authenticated;

alter table public.profiles enable row level security;
alter table public.businesses enable row level security;

create policy "profiles_select_own" on public.profiles
for select to authenticated using (id = auth.uid());

create policy "profiles_admin_select_all" on public.profiles
for select to authenticated using (public.is_admin());

create policy "profiles_update_own" on public.profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "businesses_select_own" on public.businesses
for select to authenticated using (owner_id = auth.uid());

create policy "businesses_admin_select_all" on public.businesses
for select to authenticated using (public.is_admin());

create policy "businesses_insert_own" on public.businesses
for insert to authenticated
with check (owner_id = auth.uid() and approval_status = 'pending');

create policy "businesses_update_own" on public.businesses
for update to authenticated
using (owner_id = auth.uid()) with check (owner_id = auth.uid());

revoke update on public.profiles from authenticated;
grant update (username, full_name, phone, updated_at)
on public.profiles to authenticated;

revoke update on public.businesses from authenticated;
grant update (
  business_type, business_name, representative_name, phone,
  business_number, address, description, updated_at
) on public.businesses to authenticated;
