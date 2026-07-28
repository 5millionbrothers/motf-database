create or replace function public.normalize_motf_region(
  raw_region text,
  raw_address text default null
)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(raw_address, '') ~ '(가평군|대성리)'
      then '가평'
    when coalesce(raw_region, '') ~ '(가평|대성리)'
      then '가평'
    else nullif(btrim(coalesce(raw_region, '')), '')
  end;
$$;

create or replace function public.normalize_business_region_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.region := public.normalize_motf_region(new.region, new.address);
  return new;
end;
$$;

drop trigger if exists businesses_normalize_region on public.businesses;
create trigger businesses_normalize_region
before insert or update of region, address on public.businesses
for each row execute function public.normalize_business_region_before_write();

create or replace function public.normalize_reference_point_region_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.region := public.normalize_motf_region(new.region, null);
  return new;
end;
$$;

drop trigger if exists location_reference_points_normalize_region on public.location_reference_points;
create trigger location_reference_points_normalize_region
before insert or update of region on public.location_reference_points
for each row execute function public.normalize_reference_point_region_before_write();

update public.businesses
set region = public.normalize_motf_region(region, address)
where region is distinct from public.normalize_motf_region(region, address);

update public.location_reference_points
set region = public.normalize_motf_region(region, null)
where region is distinct from public.normalize_motf_region(region, null);
