-- Fresh-install foundation for stay inventory blocks.
-- The production project already has this table from a historical manual SQL run,
-- but it was missing from the repository migration chain.

create table if not exists public.stay_availability_blocks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  offering_id uuid not null references public.offerings(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  start_date date not null,
  end_date date not null,
  source text not null default 'manual'
    check (source in ('manual', 'motf', 'external_ical', 'external_api')),
  status text not null default 'active'
    check (status in ('active', 'cancelled')),
  note text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date < end_date)
);

create index if not exists stay_blocks_offering_range_idx
on public.stay_availability_blocks(offering_id, start_date, end_date)
where status = 'active';

create index if not exists stay_blocks_business_range_idx
on public.stay_availability_blocks(business_id, start_date, end_date)
where status = 'active';

drop trigger if exists stay_availability_blocks_set_updated_at on public.stay_availability_blocks;
create trigger stay_availability_blocks_set_updated_at
before update on public.stay_availability_blocks
for each row execute procedure public.set_updated_at();

alter table public.stay_availability_blocks enable row level security;

drop policy if exists "stay_blocks_read_managers" on public.stay_availability_blocks;
create policy "stay_blocks_read_managers"
on public.stay_availability_blocks for select to authenticated
using (public.owns_business(business_id) or public.is_admin());

drop policy if exists "stay_blocks_write_managers" on public.stay_availability_blocks;
create policy "stay_blocks_write_managers"
on public.stay_availability_blocks for all to authenticated
using (public.owns_business(business_id) or public.is_admin())
with check (public.owns_business(business_id) or public.is_admin());

grant select, insert, update on public.stay_availability_blocks to authenticated;
