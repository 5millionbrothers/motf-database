-- Keep the coordinate types explicit when reference points are stored as numeric
-- and business coordinates are stored as double precision.
create or replace function public.refresh_business_nearby_distances(target_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  station_distance integer;
  convenience_distance integer;
begin
  select * into target_business from public.businesses where id = target_business_id;
  if target_business.id is null then raise exception '업장을 찾을 수 없습니다.'; end if;
  if auth.uid() is not null
     and not public.owns_business(target_business_id)
     and not public.is_admin() then
    raise exception '업장 위치를 갱신할 권한이 없습니다.';
  end if;

  if target_business.latitude is null or target_business.longitude is null then
    update public.businesses
    set station_distance_m = null, convenience_distance_m = null
    where id = target_business_id;
    return;
  end if;

  select min(public.distance_meters(
    target_business.latitude::numeric,
    target_business.longitude::numeric,
    p.latitude::numeric,
    p.longitude::numeric
  )) into station_distance
  from public.location_reference_points p
  where p.reference_type = 'station'
    and p.is_active
    and (p.region is null or target_business.region is null or p.region = target_business.region);

  select min(public.distance_meters(
    target_business.latitude::numeric,
    target_business.longitude::numeric,
    p.latitude::numeric,
    p.longitude::numeric
  )) into convenience_distance
  from public.location_reference_points p
  where p.reference_type = 'convenience'
    and p.is_active
    and (p.region is null or target_business.region is null or p.region = target_business.region);

  update public.businesses
  set station_distance_m = station_distance,
      convenience_distance_m = convenience_distance,
      nearby_tags = array(
        select distinct tag
        from unnest(
          array_remove(array_remove(coalesce(nearby_tags, '{}'), 'station'), 'convenience')
          || case when station_distance is not null and station_distance <= 500 then array['station'] else '{}'::text[] end
          || case when convenience_distance is not null and convenience_distance <= 500 then array['convenience'] else '{}'::text[] end
        ) tag
      ),
      updated_at = now()
  where id = target_business_id;
end;
$$;

revoke all on function public.refresh_business_nearby_distances(uuid) from public;
grant execute on function public.refresh_business_nearby_distances(uuid) to authenticated, service_role;

do $$
declare
  target_business record;
begin
  for target_business in
    select id from public.businesses where business_type = 'stay'
  loop
    perform public.refresh_business_nearby_distances(target_business.id);
  end loop;
end;
$$;
