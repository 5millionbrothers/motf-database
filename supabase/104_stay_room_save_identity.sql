-- Stable room IDs and serialized snapshot saves prevent repeated inserts.
begin;
create or replace function public.save_business_offerings(target_business_id uuid, items jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  item jsonb; item_id uuid; existing_item public.offerings%rowtype;
  submitted_ids uuid[] := '{}'; submitted_names text[] := '{}'; normalized_name text;
  feature_values text[]; image_values text[]; fallback_price integer; is_stay boolean; matches integer;
begin
  if not coalesce(public.has_business_permission(target_business_id,'listing') or public.is_admin(),false) then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  select b.business_type='stay' into is_stay from public.businesses b where b.id=target_business_id for update;
  if not found then raise exception '업장을 찾을 수 없습니다.'; end if;
  if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;
  for item in select value from jsonb_array_elements(items) loop
    normalized_name := lower(trim(item->>'name'));
    if coalesce(normalized_name,'')='' then raise exception '객실 또는 상품 이름을 입력해주세요.'; end if;
    if is_stay and normalized_name=any(submitted_names) then
      raise exception '같은 이름의 객실이 중복되어 있습니다. 객실 이름을 구분해주세요: %',trim(item->>'name');
    end if;
    submitted_names := array_append(submitted_names,normalized_name);
    item_id := nullif(item->>'id','')::uuid;
    if item_id is null and is_stay then
      -- Compatibility for an older portal: reuse one unambiguous existing room.
      select count(*) into matches from public.offerings o
      where o.business_id=target_business_id and o.retired_at is null and lower(trim(o.name))=normalized_name;
      if matches>1 then raise exception '중복 객실을 먼저 정리한 뒤 다시 저장해주세요: %',trim(item->>'name'); end if;
      select o.id into item_id from public.offerings o
      where o.business_id=target_business_id and o.retired_at is null and lower(trim(o.name))=normalized_name;
    end if;
    if item_id is not null then
      select * into existing_item from public.offerings o where o.id=item_id;
      if found and (existing_item.business_id<>target_business_id or existing_item.retired_at is not null) then
        raise exception '수정할 수 없는 객실 또는 상품입니다. 새로고침 후 다시 시도해주세요.';
      end if;
    end if;
    item_id := coalesce(item_id,gen_random_uuid());
    if item_id=any(submitted_ids) then raise exception '같은 객실 또는 상품이 두 번 전달되었습니다.'; end if;
    if is_stay and exists(select 1 from public.offerings o where o.business_id=target_business_id
      and o.retired_at is null and lower(trim(o.name))=normalized_name and o.id<>item_id) then
      raise exception '같은 이름의 객실이 이미 있습니다. 객실 이름을 구분해주세요: %',trim(item->>'name');
    end if;
    select coalesce(array_agg(value),'{}') into feature_values
      from jsonb_array_elements_text(case when jsonb_typeof(item->'feature_summary')='array' then item->'feature_summary' else '[]'::jsonb end);
    select coalesce(array_agg(value),'{}') into image_values
      from jsonb_array_elements_text(case when jsonb_typeof(item->'image_urls')='array' then item->'image_urls' else '[]'::jsonb end);
    fallback_price := greatest(coalesce(nullif(item->>'offseason_weekday_price','')::integer,nullif(item->>'price','')::integer,0),0);
    insert into public.offerings (
      id,business_id,name,description,price,is_active,max_people,min_people,base_people,extra_person_fee,unit,category,
      image_url,image_urls,sort_order,feature_summary,amenity_details,detail_sections,origin,nutrition_info,is_alcohol,stock_quantity,
      offseason_weekday_price,offseason_weekend_price,shoulder_weekday_price,shoulder_weekend_price,peak_weekday_price,peak_weekend_price,
      bathroom_count,bathroom_gender_separated,bathroom_note,updated_at
    ) values (
      item_id,target_business_id,trim(item->>'name'),nullif(trim(item->>'description'),''),fallback_price,
      coalesce(nullif(item->>'is_active','')::boolean,true),nullif(item->>'max_people','')::integer,nullif(item->>'min_people','')::integer,
      nullif(item->>'base_people','')::integer,nullif(item->>'extra_person_fee','')::integer,nullif(trim(item->>'unit'),''),nullif(trim(item->>'category'),''),
      coalesce(nullif(trim(item->>'image_url'),''),image_values[1]),image_values,coalesce(nullif(item->>'sort_order','')::integer,0),feature_values,
      case when jsonb_typeof(item->'amenity_details')='array' then item->'amenity_details' else '[]'::jsonb end,
      case when jsonb_typeof(item->'detail_sections')='object' then item->'detail_sections' else '{}'::jsonb end,nullif(trim(item->>'origin'),''),
      case when jsonb_typeof(item->'nutrition_info')='object' then item->'nutrition_info' else '{}'::jsonb end,
      coalesce(nullif(item->>'is_alcohol','')::boolean,false),nullif(item->>'stock_quantity','')::integer,
      coalesce(nullif(item->>'offseason_weekday_price','')::integer,fallback_price),coalesce(nullif(item->>'offseason_weekend_price','')::integer,fallback_price),
      coalesce(nullif(item->>'shoulder_weekday_price','')::integer,fallback_price),coalesce(nullif(item->>'shoulder_weekend_price','')::integer,fallback_price),
      coalesce(nullif(item->>'peak_weekday_price','')::integer,fallback_price),coalesce(nullif(item->>'peak_weekend_price','')::integer,fallback_price),
      greatest(coalesce(nullif(item->>'bathroom_count','')::integer,0),0),coalesce(nullif(item->>'bathroom_gender_separated','')::boolean,false),nullif(trim(item->>'bathroom_note'),''),now()
    ) on conflict (id) do update set
      name=excluded.name,description=excluded.description,price=excluded.price,is_active=excluded.is_active,
      max_people=excluded.max_people,min_people=excluded.min_people,base_people=excluded.base_people,extra_person_fee=excluded.extra_person_fee,
      unit=excluded.unit,category=excluded.category,image_url=excluded.image_url,image_urls=excluded.image_urls,sort_order=excluded.sort_order,
      feature_summary=excluded.feature_summary,amenity_details=excluded.amenity_details,detail_sections=excluded.detail_sections,
      origin=excluded.origin,nutrition_info=excluded.nutrition_info,is_alcohol=excluded.is_alcohol,stock_quantity=excluded.stock_quantity,
      offseason_weekday_price=excluded.offseason_weekday_price,offseason_weekend_price=excluded.offseason_weekend_price,
      shoulder_weekday_price=excluded.shoulder_weekday_price,shoulder_weekend_price=excluded.shoulder_weekend_price,
      peak_weekday_price=excluded.peak_weekday_price,peak_weekend_price=excluded.peak_weekend_price,
      bathroom_count=excluded.bathroom_count,bathroom_gender_separated=excluded.bathroom_gender_separated,bathroom_note=excluded.bathroom_note,updated_at=now();
    submitted_ids := array_append(submitted_ids,item_id);
  end loop;
  -- Removed rooms leave the editor, but historical reservations retain their FK.
  update public.offerings o set is_active=false,
    retired_at=case when is_stay then coalesce(o.retired_at,now()) else o.retired_at end,updated_at=now()
  where o.business_id=target_business_id and o.retired_at is null and not(o.id=any(submitted_ids));
  if is_stay then
    update public.businesses b set room_count=(select count(*) from public.offerings o
      where o.business_id=target_business_id and o.retired_at is null and o.is_active) where b.id=target_business_id;
  end if;
  perform public.refresh_business_highlights(target_business_id);
end;
$$;
revoke all on function public.save_business_offerings(uuid,jsonb) from public,anon;
grant execute on function public.save_business_offerings(uuid,jsonb) to authenticated;
commit;
