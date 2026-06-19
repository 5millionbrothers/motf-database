-- 적용 완료: 문의·분쟁·리뷰·커뮤니티 관리

create table public.support_cases (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  business_id uuid references public.businesses(id) on delete set null,
  reservation_id uuid references public.reservations(id) on delete set null,
  case_type text not null check (case_type in ('inquiry','dispute')),
  title text not null,
  body text not null,
  status text not null default 'received'
    check (status in ('received','processing','resolved')),
  admin_note text,
  assigned_admin uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  author_name text not null,
  rating integer not null check (rating between 1 and 5),
  body text not null,
  is_hidden boolean not null default false,
  report_count integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null,
  title text not null,
  body text not null,
  is_hidden boolean not null default false,
  report_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger support_cases_set_updated_at before update on public.support_cases
for each row execute procedure public.set_updated_at();
create trigger community_posts_set_updated_at before update on public.community_posts
for each row execute procedure public.set_updated_at();

alter table public.support_cases enable row level security;
alter table public.reviews enable row level security;
alter table public.community_posts enable row level security;

create policy "support_case_participant_read" on public.support_cases
for select to authenticated
using (
  reporter_id = auth.uid()
  or (business_id is not null and public.owns_business(business_id))
  or public.is_admin()
);
create policy "support_case_user_insert" on public.support_cases
for insert to authenticated with check (reporter_id = auth.uid());
create policy "support_case_admin_update" on public.support_cases
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "reviews_read" on public.reviews
for select to authenticated
using (not is_hidden or author_id = auth.uid() or public.owns_business(business_id) or public.is_admin());
create policy "reviews_user_insert" on public.reviews
for insert to authenticated with check (author_id = auth.uid());
create policy "reviews_admin_update" on public.reviews
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "community_read" on public.community_posts
for select to authenticated
using (not is_hidden or author_id = auth.uid() or public.is_admin());
create policy "community_user_insert" on public.community_posts
for insert to authenticated with check (author_id = auth.uid());
create policy "community_admin_update" on public.community_posts
for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update on public.support_cases to authenticated;
grant select, insert, update on public.reviews to authenticated;
grant select, insert, update on public.community_posts to authenticated;
