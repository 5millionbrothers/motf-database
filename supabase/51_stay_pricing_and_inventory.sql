-- Structured stay pricing, facilities, room metadata, and automatic nearby distances.

alter table public.businesses
  add column if not exists shoulder_season_ranges jsonb not null default '[]'::jsonb,
  add column if not exists peak_season_ranges jsonb not null default '[]'::jsonb,
  add column if not exists shared_bathroom_count integer not null default 0 check (shared_bathroom_count >= 0),
  add column if not exists shared_bathroom_gender_separated boolean not null default false,
  add column if not exists shared_bathroom_note text,
  add column if not exists highlight_keys text[] not null default '{}';

alter table public.businesses drop constraint if exists businesses_highlight_keys_limit_check;
alter table public.businesses add constraint businesses_highlight_keys_limit_check
check (cardinality(highlight_keys) <= 3);

alter table public.offerings
  add column if not exists offseason_weekday_price integer check (offseason_weekday_price is null or offseason_weekday_price >= 0),
  add column if not exists offseason_weekend_price integer check (offseason_weekend_price is null or offseason_weekend_price >= 0),
  add column if not exists shoulder_weekday_price integer check (shoulder_weekday_price is null or shoulder_weekday_price >= 0),
  add column if not exists shoulder_weekend_price integer check (shoulder_weekend_price is null or shoulder_weekend_price >= 0),
  add column if not exists peak_weekday_price integer check (peak_weekday_price is null or peak_weekday_price >= 0),
  add column if not exists peak_weekend_price integer check (peak_weekend_price is null or peak_weekend_price >= 0),
  add column if not exists bathroom_count integer not null default 0 check (bathroom_count >= 0),
  add column if not exists bathroom_gender_separated boolean not null default false,
  add column if not exists bathroom_note text;

update public.offerings
set offseason_weekday_price = coalesce(offseason_weekday_price, price),
    offseason_weekend_price = coalesce(offseason_weekend_price, price),
    shoulder_weekday_price = coalesce(shoulder_weekday_price, price),
    shoulder_weekend_price = coalesce(shoulder_weekend_price, price),
    peak_weekday_price = coalesce(peak_weekday_price, price),
    peak_weekend_price = coalesce(peak_weekend_price, price)
where offseason_weekday_price is null
   or offseason_weekend_price is null
   or shoulder_weekday_price is null
   or shoulder_weekend_price is null
   or peak_weekday_price is null
   or peak_weekend_price is null;

grant select (
  shoulder_season_ranges, peak_season_ranges, shared_bathroom_count,
  shared_bathroom_gender_separated, shared_bathroom_note, highlight_keys
) on public.businesses to anon, authenticated;

grant update (
  shoulder_season_ranges, peak_season_ranges, shared_bathroom_count,
  shared_bathroom_gender_separated, shared_bathroom_note, highlight_keys, updated_at
) on public.businesses to authenticated;

grant select (
  offseason_weekday_price, offseason_weekend_price, shoulder_weekday_price,
  shoulder_weekend_price, peak_weekday_price, peak_weekend_price,
  bathroom_count, bathroom_gender_separated, bathroom_note
) on public.offerings to anon, authenticated;

create table if not exists public.location_reference_points (
  id uuid primary key default gen_random_uuid(),
  reference_type text not null check (reference_type in ('station', 'convenience')),
  name text not null,
  region text,
  latitude numeric(10,7) not null check (latitude between -90 and 90),
  longitude numeric(10,7) not null check (longitude between -180 and 180),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists location_reference_points_type_region_idx
on public.location_reference_points(reference_type, region) where is_active;

drop trigger if exists location_reference_points_set_updated_at on public.location_reference_points;
create trigger location_reference_points_set_updated_at before update on public.location_reference_points
for each row execute procedure public.set_updated_at();

alter table public.location_reference_points enable row level security;
drop policy if exists "location_reference_points_read" on public.location_reference_points;
create policy "location_reference_points_read" on public.location_reference_points
for select to anon, authenticated using (is_active or public.is_admin());
drop policy if exists "location_reference_points_admin_write" on public.location_reference_points;
create policy "location_reference_points_admin_write" on public.location_reference_points
for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.location_reference_points to anon, authenticated;
grant insert, update, delete on public.location_reference_points to authenticated;

create or replace function public.distance_meters(
  latitude_a numeric,
  longitude_a numeric,
  latitude_b numeric,
  longitude_b numeric
)
returns integer
language sql
immutable
set search_path = ''
as $$
  select round(
    6371000 * 2 * asin(sqrt(
      power(sin(radians((latitude_b - latitude_a)::double precision) / 2), 2)
      + cos(radians(latitude_a::double precision))
      * cos(radians(latitude_b::double precision))
      * power(sin(radians((longitude_b - longitude_a)::double precision) / 2), 2)
    ))
  )::integer;
$$;

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
    target_business.latitude, target_business.longitude, p.latitude, p.longitude
  )) into station_distance
  from public.location_reference_points p
  where p.reference_type = 'station'
    and p.is_active
    and (p.region is null or target_business.region is null or p.region = target_business.region);

  select min(public.distance_meters(
    target_business.latitude, target_business.longitude, p.latitude, p.longitude
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

revoke all on function public.distance_meters(numeric,numeric,numeric,numeric) from public;
revoke all on function public.refresh_business_nearby_distances(uuid) from public;
grant execute on function public.distance_meters(numeric,numeric,numeric,numeric) to anon, authenticated, service_role;
grant execute on function public.refresh_business_nearby_distances(uuid) to authenticated, service_role;

create or replace function public.business_location_distance_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT'
     or new.latitude is distinct from old.latitude
     or new.longitude is distinct from old.longitude
     or new.region is distinct from old.region then
    perform public.refresh_business_nearby_distances(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists businesses_refresh_nearby_distances on public.businesses;
create trigger businesses_refresh_nearby_distances
after update of latitude, longitude, region on public.businesses
for each row execute function public.business_location_distance_trigger();

drop trigger if exists businesses_refresh_nearby_distances_on_insert on public.businesses;
create trigger businesses_refresh_nearby_distances_on_insert
after insert on public.businesses
for each row execute function public.business_location_distance_trigger();

create or replace function public.reference_point_distance_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_region text;
  new_region text;
  target_business record;
begin
  old_region := case when tg_op in ('UPDATE', 'DELETE') then old.region else null end;
  new_region := case when tg_op in ('INSERT', 'UPDATE') then new.region else null end;
  for target_business in
    select b.id
    from public.businesses b
    where b.business_type = 'stay'
      and b.latitude is not null
      and b.longitude is not null
      and (
        old_region is null or new_region is null or b.region is null
        or b.region = old_region or b.region = new_region
      )
  loop
    perform public.refresh_business_nearby_distances(target_business.id);
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists reference_points_refresh_business_distances on public.location_reference_points;
create trigger reference_points_refresh_business_distances
after insert or update or delete on public.location_reference_points
for each row execute function public.reference_point_distance_trigger();

create or replace function public.sync_business_room_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_business_id uuid;
begin
  affected_business_id := case when tg_op = 'DELETE' then old.business_id else new.business_id end;
  update public.businesses b
  set room_count = (
        select count(*)::integer from public.offerings o
        where o.business_id = affected_business_id and o.is_active
      ),
      bath_count = coalesce((
        select sum(o.bathroom_count)::integer from public.offerings o
        where o.business_id = affected_business_id and o.is_active
      ), 0) + coalesce(b.shared_bathroom_count, 0),
      updated_at = now()
  where b.id = affected_business_id and b.business_type = 'stay';
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists offerings_sync_business_room_totals on public.offerings;
create trigger offerings_sync_business_room_totals
after insert or update or delete on public.offerings
for each row execute function public.sync_business_room_totals();

create or replace function public.build_business_highlight_summary(
  target_business_id uuid,
  selected_keys text[]
)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  key_name text;
  result text[] := '{}';
  max_capacity integer;
  amenity jsonb;
  detail_text text;
begin
  select * into target_business from public.businesses where id = target_business_id;
  select max(o.max_people) into max_capacity
  from public.offerings o where o.business_id = target_business_id and o.is_active;

  foreach key_name in array coalesce(selected_keys, '{}') loop
    detail_text := null;
    if key_name = 'capacity' and max_capacity is not null then
      detail_text := '최대 ' || max_capacity || '명 수용';
    elsif key_name = 'rooms' and target_business.room_count > 0 then
      detail_text := '객실 ' || target_business.room_count || '개';
    elsif key_name = 'station' and target_business.station_distance_m is not null then
      detail_text := '역 ' || target_business.station_distance_m || 'm';
    elsif key_name = 'convenience' and target_business.convenience_distance_m is not null then
      detail_text := '편의점 ' || target_business.convenience_distance_m || 'm';
    else
      select item into amenity
      from jsonb_array_elements(coalesce(target_business.amenity_details, '[]'::jsonb)) item
      where item ->> 'key' = key_name and coalesce(nullif(item ->> 'available', '')::boolean, false)
      limit 1;
      if amenity is not null then
        detail_text := coalesce(nullif(amenity ->> 'label', ''), case key_name
          when 'barbecue' then '야외바베큐'
          when 'karaoke' then '노래방/마이크'
          when 'field' then '야외운동장'
          when 'pool' then '수영장'
          when 'screen' then 'TV/화면'
          when 'wifi' then '무료 와이파이'
          when 'parking' then '주차 가능'
          when 'pickup' then '픽업 가능'
          else key_name end);
        if key_name = 'parking' and nullif(amenity #>> '{params,spaces}', '') is not null then
          detail_text := '주차 ' || (amenity #>> '{params,spaces}') || '대';
        elsif key_name = 'barbecue' and nullif(amenity #>> '{params,capacity}', '') is not null then
          detail_text := '바베큐 최대 ' || (amenity #>> '{params,capacity}') || '명';
        end if;
      end if;
    end if;
    if detail_text is not null and cardinality(result) < 3 then result := array_append(result, detail_text); end if;
  end loop;
  return result;
end;
$$;

create or replace function public.refresh_business_highlights(target_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.businesses
  set highlight_summary = public.build_business_highlight_summary(id, highlight_keys)
  where id = target_business_id and cardinality(highlight_keys) > 0;
end;
$$;

revoke all on function public.build_business_highlight_summary(uuid,text[]) from public;
revoke all on function public.refresh_business_highlights(uuid) from public;
grant execute on function public.build_business_highlight_summary(uuid,text[]) to anon, authenticated, service_role;
grant execute on function public.refresh_business_highlights(uuid) to authenticated, service_role;

-- Keep existing offering IDs so reservations and availability references stay intact.
create or replace function public.save_business_offerings(target_business_id uuid, items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  item_id uuid;
  submitted_ids uuid[] := '{}';
  feature_values text[];
  image_values text[];
  fallback_price integer;
begin
  if not public.owns_business(target_business_id) and not public.is_admin() then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;

  for item in select value from jsonb_array_elements(items)
  loop
    if nullif(trim(item->>'name'), '') is null then raise exception '객실 또는 상품 이름을 입력해주세요.'; end if;
    item_id := nullif(item->>'id', '')::uuid;
    if item_id is not null and not exists (
      select 1 from public.offerings o where o.id = item_id and o.business_id = target_business_id
    ) then raise exception '수정할 수 없는 객실 또는 상품입니다.'; end if;
    item_id := coalesce(item_id, gen_random_uuid());

    select coalesce(array_agg(value), '{}') into feature_values
    from jsonb_array_elements_text(case when jsonb_typeof(item->'feature_summary') = 'array' then item->'feature_summary' else '[]'::jsonb end);
    select coalesce(array_agg(value), '{}') into image_values
    from jsonb_array_elements_text(case when jsonb_typeof(item->'image_urls') = 'array' then item->'image_urls' else '[]'::jsonb end);

    fallback_price := greatest(coalesce(
      nullif(item->>'offseason_weekday_price', '')::integer,
      nullif(item->>'price', '')::integer,
      0
    ), 0);

    insert into public.offerings (
      id, business_id, name, description, price, is_active, max_people, min_people,
      base_people, extra_person_fee, unit, category, image_url, image_urls, sort_order,
      feature_summary, amenity_details, detail_sections, origin, nutrition_info,
      is_alcohol, stock_quantity, offseason_weekday_price, offseason_weekend_price,
      shoulder_weekday_price, shoulder_weekend_price, peak_weekday_price, peak_weekend_price,
      bathroom_count, bathroom_gender_separated, bathroom_note, updated_at
    ) values (
      item_id, target_business_id, trim(item->>'name'), nullif(trim(item->>'description'), ''), fallback_price,
      coalesce(nullif(item->>'is_active', '')::boolean, true),
      nullif(item->>'max_people', '')::integer, nullif(item->>'min_people', '')::integer,
      nullif(item->>'base_people', '')::integer, nullif(item->>'extra_person_fee', '')::integer,
      nullif(trim(item->>'unit'), ''), nullif(trim(item->>'category'), ''),
      coalesce(nullif(trim(item->>'image_url'), ''), image_values[1]), image_values,
      coalesce(nullif(item->>'sort_order', '')::integer, 0), feature_values,
      case when jsonb_typeof(item->'amenity_details') = 'array' then item->'amenity_details' else '[]'::jsonb end,
      case when jsonb_typeof(item->'detail_sections') = 'object' then item->'detail_sections' else '{}'::jsonb end,
      nullif(trim(item->>'origin'), ''),
      case when jsonb_typeof(item->'nutrition_info') = 'object' then item->'nutrition_info' else '{}'::jsonb end,
      coalesce(nullif(item->>'is_alcohol', '')::boolean, false), nullif(item->>'stock_quantity', '')::integer,
      coalesce(nullif(item->>'offseason_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'offseason_weekend_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'shoulder_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'shoulder_weekend_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'peak_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'peak_weekend_price', '')::integer, fallback_price),
      greatest(coalesce(nullif(item->>'bathroom_count', '')::integer, 0), 0),
      coalesce(nullif(item->>'bathroom_gender_separated', '')::boolean, false),
      nullif(trim(item->>'bathroom_note'), ''), now()
    )
    on conflict (id) do update set
      name = excluded.name, description = excluded.description, price = excluded.price,
      is_active = excluded.is_active, max_people = excluded.max_people, min_people = excluded.min_people,
      base_people = excluded.base_people, extra_person_fee = excluded.extra_person_fee,
      unit = excluded.unit, category = excluded.category, image_url = excluded.image_url,
      image_urls = excluded.image_urls, sort_order = excluded.sort_order,
      feature_summary = excluded.feature_summary, amenity_details = excluded.amenity_details,
      detail_sections = excluded.detail_sections, origin = excluded.origin,
      nutrition_info = excluded.nutrition_info, is_alcohol = excluded.is_alcohol,
      stock_quantity = excluded.stock_quantity,
      offseason_weekday_price = excluded.offseason_weekday_price,
      offseason_weekend_price = excluded.offseason_weekend_price,
      shoulder_weekday_price = excluded.shoulder_weekday_price,
      shoulder_weekend_price = excluded.shoulder_weekend_price,
      peak_weekday_price = excluded.peak_weekday_price,
      peak_weekend_price = excluded.peak_weekend_price,
      bathroom_count = excluded.bathroom_count,
      bathroom_gender_separated = excluded.bathroom_gender_separated,
      bathroom_note = excluded.bathroom_note,
      updated_at = now();
    submitted_ids := array_append(submitted_ids, item_id);
  end loop;

  update public.offerings set is_active = false, updated_at = now()
  where business_id = target_business_id and not (id = any(submitted_ids));
  perform public.refresh_business_highlights(target_business_id);
end;
$$;

revoke all on function public.save_business_offerings(uuid,jsonb) from public;
grant execute on function public.save_business_offerings(uuid,jsonb) to authenticated;

create or replace function public.stay_season_for_date(target_business_id uuid, target_date date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
begin
  select * into target_business from public.businesses where id = target_business_id;
  if exists (
    select 1 from jsonb_array_elements(coalesce(target_business.peak_season_ranges, '[]'::jsonb)) item
    where target_date between (item->>'start_date')::date and (item->>'end_date')::date
  ) then return 'peak'; end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(target_business.shoulder_season_ranges, '[]'::jsonb)) item
    where target_date between (item->>'start_date')::date and (item->>'end_date')::date
  ) then return 'shoulder'; end if;
  return 'offseason';
end;
$$;

create or replace function public.stay_price_for_date(target_offering_id uuid, target_date date)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  room public.offerings%rowtype;
  season_name text;
  weekend boolean;
begin
  select * into room from public.offerings where id = target_offering_id and is_active;
  if room.id is null then raise exception '객실을 찾을 수 없습니다.'; end if;
  season_name := public.stay_season_for_date(room.business_id, target_date);
  weekend := extract(isodow from target_date) in (5, 6);
  return greatest(coalesce(case
    when season_name = 'peak' and weekend then room.peak_weekend_price
    when season_name = 'peak' then room.peak_weekday_price
    when season_name = 'shoulder' and weekend then room.shoulder_weekend_price
    when season_name = 'shoulder' then room.shoulder_weekday_price
    when weekend then room.offseason_weekend_price
    else room.offseason_weekday_price
  end, room.price, 0), 0);
end;
$$;

create or replace function public.calculate_stay_base_amount(
  target_offering_id uuid,
  target_check_in date,
  target_check_out date
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  stay_date date;
  total integer := 0;
begin
  if target_check_in is null or target_check_out is null or target_check_in >= target_check_out then
    raise exception '숙박 일정을 다시 확인해주세요.';
  end if;
  for stay_date in
    select generate_series(target_check_in, target_check_out - 1, interval '1 day')::date
  loop
    total := total + public.stay_price_for_date(target_offering_id, stay_date);
  end loop;
  return total;
end;
$$;

revoke all on function public.stay_season_for_date(uuid,date) from public;
revoke all on function public.stay_price_for_date(uuid,date) from public;
revoke all on function public.calculate_stay_base_amount(uuid,date,date) from public;
grant execute on function public.stay_season_for_date(uuid,date) to anon, authenticated, service_role;
grant execute on function public.stay_price_for_date(uuid,date) to anon, authenticated, service_role;
grant execute on function public.calculate_stay_base_amount(uuid,date,date) to anon, authenticated, service_role;

-- Initial checkout charges room accommodation only. Extra people/facilities are settled separately.
create or replace function public.prepare_stay_payment(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null,
  check_in_date date default null,
  check_out_date date default null
)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  selected_business public.businesses%rowtype;
  new_order_id text;
  actual_check_in date := coalesce(check_in_date, event_date);
  actual_check_out date := coalesce(check_out_date, event_date + 1);
  included_people integer;
  extra_people integer;
  calculated_amount integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'user' and status = 'approved') then
    raise exception '현재 계정으로 예약할 수 없습니다.';
  end if;
  if nullif(trim(customer_name), '') is null then raise exception '대표자 이름이 필요합니다.'; end if;
  if actual_check_in < current_date then raise exception '지난 날짜는 예약할 수 없습니다.'; end if;
  if actual_check_in >= actual_check_out then raise exception '숙박 일정을 다시 확인해주세요.'; end if;
  if guest_count is null or guest_count <= 0 then raise exception '예약 인원이 필요합니다.'; end if;

  select o.* into selected_offering from public.offerings o
  where o.id = target_offering_id and o.business_id = target_business_id and o.is_active;
  select b.* into selected_business from public.businesses b
  where b.id = target_business_id and b.business_type = 'stay' and b.approval_status = 'approved';

  if selected_offering.id is null or selected_business.id is null then raise exception '예약 가능한 객실을 찾지 못했습니다.'; end if;
  if selected_offering.max_people is not null and guest_count > selected_offering.max_people then raise exception '객실 최대 인원을 초과했습니다.'; end if;
  if not public.stay_range_is_available(selected_offering.id, actual_check_in, actual_check_out) then raise exception '선택한 날짜에 이미 예약된 객실입니다.'; end if;

  calculated_amount := public.calculate_stay_base_amount(selected_offering.id, actual_check_in, actual_check_out);
  if calculated_amount <= 0 then raise exception '객실 요금이 올바르지 않습니다.'; end if;
  included_people := greatest(1, coalesce(selected_offering.base_people, selected_offering.min_people, selected_offering.max_people, guest_count));
  extra_people := greatest(0, guest_count - included_people);

  loop
    new_order_id := 'MS-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (select 1 from public.payment_intents pi where pi.order_id = new_order_id);
  end loop;

  insert into public.payment_intents (order_id, customer_id, kind, amount, order_name, draft)
  values (
    new_order_id, auth.uid(), 'stay', calculated_amount,
    left(selected_business.business_name || ' ' || selected_offering.name, 100),
    jsonb_build_object(
      'business_id', selected_business.id, 'offering_id', selected_offering.id,
      'offering_name', selected_offering.name, 'customer_name', trim(customer_name),
      'group_name', nullif(trim(group_name), ''), 'contact_phone', nullif(trim(contact_phone), ''),
      'event_date', actual_check_in, 'check_in_date', actual_check_in, 'check_out_date', actual_check_out,
      'guest_count', guest_count, 'base_people', included_people, 'extra_people', extra_people,
      'extra_person_fee', coalesce(selected_offering.extra_person_fee, 0),
      'extras_payment_rule', 'post_stay_separate_payment',
      'request_memo', nullif(trim(request_memo), '')
    )
  );

  return query select new_order_id, calculated_amount,
    left(selected_business.business_name || ' ' || selected_offering.name, 100), 'stay'::text;
end;
$$;

revoke all on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text,date,date) from public;
grant execute on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text,date,date) to authenticated;

comment on column public.offerings.extra_person_fee is 'Reference rate collected later through an extra-charge request, not at initial booking checkout';
comment on column public.businesses.highlight_keys is 'Up to three fixed template keys used to generate listing-card facts';
comment on table public.location_reference_points is 'Admin-managed station and convenience-store coordinates used for automatic distance calculation';
