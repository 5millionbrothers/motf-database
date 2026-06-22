-- Store verified map coordinates for public catalog markers.

alter table public.businesses
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists location_verified_at timestamptz;

alter table public.businesses
  drop constraint if exists businesses_latitude_range,
  add constraint businesses_latitude_range
    check (latitude is null or latitude between -90 and 90),
  drop constraint if exists businesses_longitude_range,
  add constraint businesses_longitude_range
    check (longitude is null or longitude between -180 and 180),
  drop constraint if exists businesses_coordinate_pair,
  add constraint businesses_coordinate_pair
    check ((latitude is null) = (longitude is null));

grant update (latitude, longitude, location_verified_at, updated_at)
on public.businesses to authenticated;

grant select (latitude, longitude, location_verified_at)
on public.businesses to anon;

comment on column public.businesses.latitude is 'Naver geocoded latitude for the public catalog marker';
comment on column public.businesses.longitude is 'Naver geocoded longitude for the public catalog marker';
comment on column public.businesses.location_verified_at is 'Last time the saved address was geocoded';
