-- Admin-only lodging website importer: source traceability, draft caching and audit state.

alter table public.businesses
  add column if not exists source_url text,
  add column if not exists import_job_id uuid,
  add column if not exists imported_at timestamptz;

create unique index if not exists businesses_source_url_unique_idx
on public.businesses(source_url)
where source_url is not null;

create table if not exists public.stay_import_jobs (
  id uuid primary key default gen_random_uuid(),
  source_url text not null,
  canonical_url text not null,
  source_hash text not null,
  status text not null default 'analyzed'
    check (status in ('analyzing', 'analyzed', 'committed', 'failed', 'cancelled')),
  draft jsonb not null default '{}'::jsonb,
  crawled_pages text[] not null default '{}',
  image_candidates text[] not null default '{}',
  warnings text[] not null default '{}',
  error_message text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  business_id uuid references public.businesses(id) on delete set null,
  account_email text,
  committed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.businesses
  drop constraint if exists businesses_import_job_id_fkey;
alter table public.businesses
  add constraint businesses_import_job_id_fkey
  foreign key (import_job_id) references public.stay_import_jobs(id) on delete set null;

create index if not exists stay_import_jobs_source_hash_idx
on public.stay_import_jobs(source_hash, updated_at desc);

create index if not exists stay_import_jobs_created_by_idx
on public.stay_import_jobs(created_by, created_at desc);

drop trigger if exists stay_import_jobs_set_updated_at on public.stay_import_jobs;
create trigger stay_import_jobs_set_updated_at before update on public.stay_import_jobs
for each row execute procedure public.set_updated_at();

alter table public.stay_import_jobs enable row level security;

drop policy if exists "stay_import_jobs_admin_all" on public.stay_import_jobs;
create policy "stay_import_jobs_admin_all" on public.stay_import_jobs
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

grant select, insert, update, delete on public.stay_import_jobs to authenticated;
grant select (source_url, imported_at) on public.businesses to anon, authenticated;

comment on table public.stay_import_jobs is
  'Admin-reviewed drafts extracted from official lodging websites. Passwords are never stored.';
comment on column public.businesses.source_url is
  'Official source page used by an administrator to import this listing.';
