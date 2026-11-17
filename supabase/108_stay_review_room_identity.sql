-- Resolve old draft IDs against the current room before replacing a stay snapshot.
begin;
create or replace function public.resolve_stay_offering_snapshot(target_business_id uuid,items jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; room public.offerings%rowtype; item_id uuid; matched_id uuid; matches integer;
  names text[]:='{}'; ids uuid[]:='{}'; room_name text; result jsonb:='[]'; is_stay boolean;
begin
  select business_type='stay' into is_stay from public.businesses where id=target_business_id for update;
  if not found then raise exception '업장을 찾을 수 없습니다.'; end if;
  if not is_stay then return items; end if;
  if items is null or jsonb_typeof(items)<>'array' then raise exception '객실 목록을 확인해주세요.'; end if;
  for item in select value from jsonb_array_elements(items) loop
    room_name:=lower(trim(item->>'name'));
    if coalesce(room_name,'')='' then raise exception '객실 이름을 입력해주세요.'; end if;
    if room_name=any(names) then raise exception '신청서에 같은 이름의 객실이 두 번 있습니다: %',trim(item->>'name'); end if;
    names:=array_append(names,room_name);
    item_id:=nullif(item->>'id','')::uuid;
    select * into room from public.offerings where id=item_id;
    if found and room.business_id<>target_business_id then raise exception '다른 업장의 객실은 수정할 수 없습니다.'; end if;
    if room.id is null or room.retired_at is not null then
      -- A stale/generated ID must not turn the same physical room into a new row.
      select count(*),min(o.id::text)::uuid into matches,matched_id from public.offerings o
      where o.business_id=target_business_id and o.retired_at is null and lower(trim(o.name))=room_name;
      if matches>1 then raise exception '현재 저장된 객실에 같은 이름이 여러 개 있습니다. 운영팀 확인이 필요합니다: %',trim(item->>'name'); end if;
      if matched_id is not null then item_id:=matched_id;
      elsif room.retired_at is not null then raise exception '삭제된 객실의 이전 신청입니다. 최신 객실 목록으로 다시 신청해주세요: %',trim(item->>'name');
      else item_id:=coalesce(item_id,gen_random_uuid()); end if;
    end if;
    if item_id=any(ids) then raise exception '한 객실이 신청서에 두 번 연결되어 있습니다: %',trim(item->>'name'); end if;
    ids:=array_append(ids,item_id);
    result:=result||jsonb_build_array(jsonb_set(item,'{id}',to_jsonb(item_id::text)));
  end loop;
  return result;
end;
$$;
revoke all on function public.resolve_stay_offering_snapshot(uuid,jsonb) from public,anon,authenticated;

create or replace function public.save_business_offerings(target_business_id uuid,items jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare item jsonb; item_id uuid; existing_item public.offerings%rowtype;
  submitted_ids uuid[]:='{}';feature_values text[];image_values text[];fallback_price integer;is_stay boolean;
begin
  if not coalesce(public.has_business_permission(target_business_id,'listing') or public.is_admin(),false) then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  select b.business_type='stay' into is_stay from public.businesses b where b.id=target_business_id for update;
  if not found then raise exception '업장을 찾을 수 없습니다.'; end if;
  if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;
  items:=public.resolve_stay_offering_snapshot(target_business_id,items);
  for item in select value from jsonb_array_elements(items) loop
    if coalesce(trim(item->>'name'),'')='' then raise exception '객실 또는 상품 이름을 입력해주세요.'; end if;
    item_id:=nullif(item->>'id','')::uuid;
    if item_id is not null then
      select * into existing_item from public.offerings o where o.id=item_id;
      if found and (existing_item.business_id<>target_business_id or existing_item.retired_at is not null) then
        raise exception '수정할 수 없는 객실 또는 상품입니다. 새로고침 후 다시 시도해주세요.';
      end if;
    end if;
    item_id:=coalesce(item_id,gen_random_uuid());
    if item_id=any(submitted_ids) then raise exception '같은 객실 또는 상품이 두 번 전달되었습니다.'; end if;
    select coalesce(array_agg(value),'{}') into feature_values
      from jsonb_array_elements_text(case when jsonb_typeof(item->'feature_summary')='array' then item->'feature_summary' else '[]'::jsonb end);
    select coalesce(array_agg(value),'{}') into image_values
      from jsonb_array_elements_text(case when jsonb_typeof(item->'image_urls')='array' then item->'image_urls' else '[]'::jsonb end);
    fallback_price:=greatest(coalesce(nullif(item->>'offseason_weekday_price','')::integer,nullif(item->>'price','')::integer,0),0);
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
    ) on conflict(id) do update set
      name=excluded.name,description=excluded.description,price=excluded.price,is_active=excluded.is_active,
      max_people=excluded.max_people,min_people=excluded.min_people,base_people=excluded.base_people,extra_person_fee=excluded.extra_person_fee,
      unit=excluded.unit,category=excluded.category,image_url=excluded.image_url,image_urls=excluded.image_urls,sort_order=excluded.sort_order,
      feature_summary=excluded.feature_summary,amenity_details=excluded.amenity_details,detail_sections=excluded.detail_sections,
      origin=excluded.origin,nutrition_info=excluded.nutrition_info,is_alcohol=excluded.is_alcohol,stock_quantity=excluded.stock_quantity,
      offseason_weekday_price=excluded.offseason_weekday_price,offseason_weekend_price=excluded.offseason_weekend_price,
      shoulder_weekday_price=excluded.shoulder_weekday_price,shoulder_weekend_price=excluded.shoulder_weekend_price,
      peak_weekday_price=excluded.peak_weekday_price,peak_weekend_price=excluded.peak_weekend_price,
      bathroom_count=excluded.bathroom_count,bathroom_gender_separated=excluded.bathroom_gender_separated,bathroom_note=excluded.bathroom_note,updated_at=now();
    submitted_ids:=array_append(submitted_ids,item_id);
  end loop;
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

-- Persist the resolved IDs in the accepted request and never reactivate old copies.
create or replace function public.review_business_listing_request(target_request_id uuid,decision text,note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare request_row public.business_listing_review_requests%rowtype;patch jsonb;is_market boolean;resolved jsonb;
begin
 if not coalesce(public.is_admin(),false) then raise exception '관리자 권한이 필요합니다.'; end if;
 if decision is null or decision not in ('approved','rejected') then raise exception '승인 또는 반려를 선택해주세요.'; end if;
 select * into request_row from public.business_listing_review_requests where id=target_request_id and status='pending' for update;
 if request_row.id is null then raise exception '처리할 심사 요청을 찾지 못했습니다.'; end if;
 select business_type='market' into is_market from public.businesses where id=request_row.business_id for update;
 if decision='approved' then
  resolved:=request_row.proposed_offerings;
  if not coalesce(is_market,false) then resolved:=public.resolve_stay_offering_snapshot(request_row.business_id,resolved); end if;
  patch=request_row.proposed_business;
  update public.businesses b set
   business_name=coalesce(nullif(trim(patch->>'business_name'),''),b.business_name),
   representative_name=coalesce(nullif(trim(patch->>'representative_name'),''),b.representative_name),
   phone=nullif(trim(patch->>'phone'),''),business_number=nullif(trim(patch->>'business_number'),''),business_start_date=nullif(patch->>'business_start_date','')::date,
   region=nullif(trim(patch->>'region'),''),postal_code=nullif(trim(patch->>'postal_code'),''),address=nullif(trim(patch->>'address'),''),address_detail=nullif(trim(patch->>'address_detail'),''),
   description=nullif(trim(patch->>'description'),''),short_description=nullif(trim(patch->>'short_description'),''),
   highlight_keys=case when jsonb_typeof(patch->'highlight_keys')='array' then array(select jsonb_array_elements_text(patch->'highlight_keys')) else b.highlight_keys end,
   facilities=case when jsonb_typeof(patch->'facilities')='array' then array(select jsonb_array_elements_text(patch->'facilities')) else b.facilities end,
   nearby_tags=case when jsonb_typeof(patch->'nearby_tags')='array' then array(select jsonb_array_elements_text(patch->'nearby_tags')) else b.nearby_tags end,
   gallery_image_urls=case when jsonb_typeof(patch->'gallery_image_urls')='array' then array(select jsonb_array_elements_text(patch->'gallery_image_urls')) else b.gallery_image_urls end,
   cover_image_url=nullif(trim(patch->>'cover_image_url'),''),shared_bathroom_count=greatest(coalesce(nullif(patch->>'shared_bathroom_count','')::integer,0),0),
   shared_bathroom_gender_separated=coalesce(nullif(patch->>'shared_bathroom_gender_separated','')::boolean,false),shared_bathroom_note=nullif(trim(patch->>'shared_bathroom_note'),''),
   shoulder_season_ranges=case when jsonb_typeof(patch->'shoulder_season_ranges')='array' then patch->'shoulder_season_ranges' else b.shoulder_season_ranges end,
   peak_season_ranges=case when jsonb_typeof(patch->'peak_season_ranges')='array' then patch->'peak_season_ranges' else b.peak_season_ranges end,
   amenity_details=case when jsonb_typeof(patch->'amenity_details')='array' then patch->'amenity_details' else b.amenity_details end,
   extra_fees=case when jsonb_typeof(patch->'extra_fees')='array' then patch->'extra_fees' else b.extra_fees end,
   latitude=nullif(patch->>'latitude','')::numeric,longitude=nullif(patch->>'longitude','')::numeric,location_verified_at=nullif(patch->>'location_verified_at','')::timestamptz,
   approval_status=case when request_row.request_type='new_listing' then 'approved' else b.approval_status end,rejection_reason=null,updated_at=now()
  where b.id=request_row.business_id;
  if not coalesce(is_market,false) then
   if jsonb_array_length(resolved)>0 then perform public.save_business_offerings(request_row.business_id,resolved);
   else
    update public.offerings set is_active=false,retired_at=coalesce(retired_at,now()),updated_at=now() where business_id=request_row.business_id and retired_at is null;
    update public.businesses set room_count=0 where id=request_row.business_id;
   end if;
  end if;
  if request_row.request_type='new_listing' then
   update public.profiles set role='partner',status='approved',updated_at=now() where id=request_row.requester_id;
  end if;
  perform public.refresh_business_highlights(request_row.business_id);
  perform public.refresh_business_nearby_distances(request_row.business_id);
 elsif request_row.request_type='new_listing' then
  update public.businesses set rejection_reason=nullif(trim(note),''),updated_at=now() where id=request_row.business_id;
 end if;
 update public.business_listing_review_requests set status=decision,review_note=nullif(trim(note),''),
   proposed_offerings=case when decision='approved' and not coalesce(is_market,false) then resolved else proposed_offerings end,
   reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=target_request_id;
end;
$$;
revoke all on function public.review_business_listing_request(uuid,text,text) from public,anon;
grant execute on function public.review_business_listing_request(uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
