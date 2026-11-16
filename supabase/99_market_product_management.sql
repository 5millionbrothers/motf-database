-- Product-level market review and audit. Apply after 97; never re-run the launch reset.
begin;
alter table public.offerings add column if not exists market_review_status text not null default 'approved'
  check(market_review_status in ('pending','approved','rejected'));
alter table public.offerings add column if not exists market_review_note text;
alter table public.offerings add column if not exists market_submitted_by uuid references public.profiles(id) on delete set null;
alter table public.offerings add column if not exists market_submitted_at timestamptz;
alter table public.offerings add column if not exists market_reviewed_by uuid references public.profiles(id) on delete set null;
alter table public.offerings add column if not exists market_reviewed_at timestamptz;
alter table public.offerings add column if not exists market_submission_key uuid;
create unique index if not exists market_product_submission_key on public.offerings(business_id,market_submission_key) where market_submission_key is not null;

create or replace function public.market_product_category(category_name text,product_name text default '')
returns text language sql immutable set search_path='' as $$
 select case when product_name like '%물티슈%' then '일회용품'
 when category_name in ('김치·반찬','김치반찬','채소·농산물','채소농산물') then '채소·김치·반찬'
 when category_name in ('통조림·가공식품','통조림가공식품','조미료·소스','조미료소스') then '가공식품·조미료'
 when category_name='생활용품' or nullif(trim(category_name),'') is null then '기타' else trim(category_name) end;
$$;
-- Canonical labels also prevent an old review payload from restoring removed categories.
update public.offerings o set category=public.market_product_category(o.category,o.name),is_alcohol=case when o.category='주류' then true else o.is_alcohol end
from public.businesses b where b.id=o.business_id and b.business_type='market'
 and (o.category is distinct from public.market_product_category(o.category,o.name) or o.category='주류' and not o.is_alcohol);

create table if not exists public.market_product_changes (
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 offering_id uuid,actor_id uuid references public.profiles(id) on delete set null,
 action text not null, before_data jsonb,after_data jsonb,created_at timestamptz not null default now(),
 seen_at timestamptz,seen_by uuid references public.profiles(id) on delete set null
);
create index if not exists market_product_changes_created_idx on public.market_product_changes(created_at desc);
create index if not exists market_product_changes_unseen_idx on public.market_product_changes(created_at) where seen_at is null;
alter table public.market_product_changes enable row level security;
revoke all on public.market_product_changes from public,anon,authenticated;
grant select on public.market_product_changes to authenticated;
drop policy if exists market_changes_admin_read on public.market_product_changes;
create policy market_changes_admin_read on public.market_product_changes for select to authenticated using(public.is_admin());

create or replace function public.market_catalog_admin_context()
returns boolean language sql stable security definer set search_path='' as $$
 select public.is_admin() or coalesce(auth.role(),'')='service_role'
 or coalesce(current_setting('role',true),'none') not in ('authenticated','anon');
$$;
revoke all on function public.market_catalog_admin_context() from public,anon,authenticated;

create or replace function public.validate_market_product(p jsonb)
returns void language plpgsql set search_path='' as $$
declare url text; key text; n bigint;
begin
 if jsonb_typeof(p)<>'object' or octet_length(p::text)>250000 then raise exception '상품 정보 형식이 올바르지 않습니다.'; end if;
 if nullif(trim(p->>'name'),'') is null or length(p->>'name')>200 then raise exception '상품명을 확인해주세요.'; end if;
 if nullif(trim(p->>'unit'),'') is null or length(p->>'unit')>80 then raise exception '판매 단위·용량을 입력해주세요.'; end if;
 if nullif(trim(p->>'category'),'') is null then raise exception '상품 분류를 선택해주세요.'; end if;
 if coalesce(p->>'price','') !~ '^[0-9]{1,8}$' or (p->>'price')::bigint<1 then raise exception '판매가는 1원 이상의 정수로 입력해주세요.'; end if;
 if nullif(trim(p->>'origin'),'') is null then raise exception '원산지·제조국을 입력해주세요.'; end if;
 if nullif(trim(p->>'description'),'') is null or length(p->>'description')>5000 then raise exception '상품 설명을 확인해주세요.'; end if;
 if jsonb_typeof(p->'image_urls') is distinct from 'array' or jsonb_array_length(p->'image_urls') not between 1 and 100 then raise exception '상품 사진을 1장 이상 등록해주세요.'; end if;
 for url in select jsonb_array_elements_text(p->'image_urls') loop
  if url !~ '^https?://[^[:space:]<>]+$' or length(url)>3000 then raise exception '상품 사진 주소를 확인해주세요.'; end if;
 end loop;
 if p->>'image_url' is not null and (p->>'image_url' !~ '^https?://[^[:space:]<>]+$' or length(p->>'image_url')>3000) then raise exception '대표 사진 주소를 확인해주세요.'; end if;
 if jsonb_typeof(p->'detail_sections') is distinct from 'object' then raise exception '상품 상세 정보 형식이 올바르지 않습니다.'; end if;
 foreach key in array array['minimumOrderQuantity','quantityStep'] loop
  if coalesce(p->'detail_sections'->>key,'1') !~ '^[0-9]{1,4}$' then raise exception '최소 주문량·주문 단위를 확인해주세요.'; end if;
  n=coalesce(p->'detail_sections'->>key,'1')::bigint;
  if n not between 1 and 1000 then raise exception '최소 주문량·주문 단위는 1~1000입니다.'; end if;
 end loop;
 if p->>'stock_quantity' is not null and (p->>'stock_quantity' !~ '^[0-9]{1,9}$') then raise exception '재고는 0 이상의 정수로 입력해주세요.'; end if;
end;
$$;
revoke all on function public.validate_market_product(jsonb) from public,anon,authenticated;

create or replace function public.guard_market_product_review()
returns trigger language plpgsql security definer set search_path='' as $$
declare is_market boolean; trusted boolean=public.market_catalog_admin_context();
begin
 if tg_op='DELETE' then
  if exists(select 1 from public.businesses where id=old.business_id and business_type='market') and not trusted then
   raise exception '상품은 재고·품절 관리의 삭제 기능으로 삭제해주세요.';
  end if; return old;
 end if;
 if tg_op='UPDATE' and new.business_id is distinct from old.business_id then
  if exists(select 1 from public.businesses where id in (old.business_id,new.business_id) and business_type='market') then raise exception '상품의 업장은 변경할 수 없습니다.'; end if;
 end if;
 select b.business_type='market' into is_market from public.businesses b where b.id=new.business_id;
 if not coalesce(is_market,false) then return new; end if;
 if tg_op='UPDATE' and new.id is distinct from old.id then raise exception '상품 식별자는 변경할 수 없습니다.'; end if;
 new.category=public.market_product_category(new.category,new.name);
 if new.category='주류' then new.is_alcohol=true; end if;
 if tg_op='INSERT' then
  new.market_review_status='pending';new.is_active=false;new.market_reviewed_at=null;new.market_reviewed_by=null;new.market_review_note=null;
  new.market_submitted_by=auth.uid();new.market_submitted_at=now();
  if not trusted then perform public.validate_market_product(to_jsonb(new)); end if;
 else
  if not trusted then
   if not public.has_business_permission(old.business_id,'listing') then
    if not public.has_business_permission(old.business_id,'availability') or
     (to_jsonb(new)-array['updated_at','is_active','stock_quantity']) is distinct from (to_jsonb(old)-array['updated_at','is_active','stock_quantity']) then raise exception '상품 정보 수정 권한이 없습니다.'; end if;
   end if;
   new.market_review_status=case when old.market_review_status='rejected' and new.market_review_status='pending' and public.has_business_permission(old.business_id,'listing') then 'pending' else old.market_review_status end;
   new.market_submitted_by=old.market_submitted_by;new.market_submitted_at=old.market_submitted_at;new.market_submission_key=old.market_submission_key;
   new.market_review_note=old.market_review_note;new.market_reviewed_by=old.market_reviewed_by;new.market_reviewed_at=old.market_reviewed_at;
  end if;
  if new.market_review_status='pending' and old.market_review_status='rejected' then
   new.market_submitted_at=now();new.market_submitted_by=auth.uid();new.market_review_note=null;
  end if;
 end if;
 if new.market_review_status<>'approved' or new.retired_at is not null then new.is_active=false; end if;
 if tg_op='UPDATE' and not trusted and new.retired_at is null and
  (to_jsonb(new)-array['updated_at','sort_order','is_active','stock_quantity']) is distinct from (to_jsonb(old)-array['updated_at','sort_order','is_active','stock_quantity']) then
  perform public.validate_market_product(to_jsonb(new));
 end if;
 return new;
end;
$$;
drop trigger if exists market_product_review_guard on public.offerings;
create trigger market_product_review_guard before insert or update or delete on public.offerings for each row execute function public.guard_market_product_review();

create or replace function public.audit_market_product_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare before_value jsonb;after_value jsonb;action_name text;bid uuid;oid uuid;
begin
 if auth.uid() is null then return null; end if;
 if tg_op='DELETE' then bid=old.business_id;oid=old.id;before_value=to_jsonb(old);action_name='deleted';
 else bid=new.business_id;oid=new.id;after_value=to_jsonb(new);
  if tg_op='INSERT' then action_name='submitted'; else
   before_value=to_jsonb(old);
   if (before_value-array['updated_at','sort_order'])=(after_value-array['updated_at','sort_order']) then return null; end if;
   action_name=case when old.retired_at is null and new.retired_at is not null then 'deleted'
    when old.market_review_status is distinct from new.market_review_status then 'review_'||new.market_review_status else 'updated' end;
  end if;
 end if;
 if not exists(select 1 from public.businesses where id=bid and business_type='market') then return null; end if;
 insert into public.market_product_changes(business_id,offering_id,actor_id,action,before_data,after_data,seen_at)
 values(bid,oid,auth.uid(),action_name,before_value,after_value,case when action_name in ('updated','deleted') and not public.is_admin() then null else now() end);
 return null;
end;
$$;
drop trigger if exists market_product_change_audit on public.offerings;
create trigger market_product_change_audit after insert or update or delete on public.offerings for each row execute function public.audit_market_product_change();
revoke all on function public.guard_market_product_review(),public.audit_market_product_change() from public,anon,authenticated;

create or replace function public.save_market_product(target_business_id uuid,product_data jsonb,target_product_id uuid default null,expected_updated_at timestamptz default null,request_key uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item public.offerings%rowtype;images text[];details jsonb;category_value text;
begin
 if auth.uid() is null or (not public.has_business_permission(target_business_id,'listing') and not public.is_admin()) then raise exception '상품 수정 권한이 없습니다.'; end if;
 if not exists(select 1 from public.businesses where id=target_business_id and business_type='market') then raise exception '공판장 상품만 관리할 수 있습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_business_id::text,99));
 perform public.validate_market_product(product_data);
 select array_agg(value) into images from jsonb_array_elements_text(product_data->'image_urls');
 details=product_data->'detail_sections';category_value=public.market_product_category(product_data->>'category',product_data->>'name');
 if target_product_id is null then
  if request_key is null then raise exception '등록 요청 식별자가 필요합니다.'; end if;
  select * into item from public.offerings where business_id=target_business_id and market_submission_key=request_key;
  if found then return to_jsonb(item); end if;
  insert into public.offerings(business_id,name,description,price,unit,category,origin,image_url,image_urls,detail_sections,nutrition_info,is_alcohol,stock_quantity,sort_order,market_submission_key)
  values(target_business_id,trim(product_data->>'name'),trim(product_data->>'description'),(product_data->>'price')::integer,trim(product_data->>'unit'),category_value,trim(product_data->>'origin'),images[1],images,details,
   case when jsonb_typeof(product_data->'nutrition_info')='object' then product_data->'nutrition_info' else '{}' end,coalesce((product_data->>'is_alcohol')::boolean,false),nullif(product_data->>'stock_quantity','')::integer,
   (select coalesce(max(o.sort_order),-1)+1 from public.offerings o where o.business_id=target_business_id),request_key) returning * into item;
 else
  select * into item from public.offerings where id=target_product_id and business_id=target_business_id and retired_at is null for update;
  if item.id is null then raise exception '상품을 찾을 수 없습니다.'; end if;
  if expected_updated_at is null or item.updated_at is distinct from expected_updated_at then raise exception '다른 작업에서 상품이 변경되었습니다. 다시 열어 확인해주세요.'; end if;
  update public.offerings set name=trim(product_data->>'name'),description=trim(product_data->>'description'),price=(product_data->>'price')::integer,unit=trim(product_data->>'unit'),category=category_value,origin=trim(product_data->>'origin'),
   image_url=images[1],image_urls=images,detail_sections=details,nutrition_info=case when jsonb_typeof(product_data->'nutrition_info')='object' then product_data->'nutrition_info' else '{}' end,
   is_alcohol=coalesce((product_data->>'is_alcohol')::boolean,false),stock_quantity=nullif(product_data->>'stock_quantity','')::integer,
   market_review_status=case when market_review_status='rejected' then 'pending' else market_review_status end,updated_at=clock_timestamp()
  where id=item.id returning * into item;
 end if;
 return to_jsonb(item);
end;
$$;

create or replace function public.delete_market_product(target_product_id uuid,expected_updated_at timestamptz)
returns void language plpgsql security definer set search_path='' as $$
declare item public.offerings%rowtype;
begin
 select * into item from public.offerings where id=target_product_id and retired_at is null for update;
 if item.id is null or not exists(select 1 from public.businesses where id=item.business_id and business_type='market') then raise exception '상품을 찾을 수 없습니다.'; end if;
 if not public.has_business_permission(item.business_id,'listing') and not public.is_admin() then raise exception '상품 삭제 권한이 없습니다.'; end if;
 if expected_updated_at is null or item.updated_at is distinct from expected_updated_at then raise exception '상품이 변경되었습니다. 새로고침 후 다시 삭제해주세요.'; end if;
 update public.offerings set retired_at=clock_timestamp(),is_active=false,updated_at=clock_timestamp() where id=item.id;
end;
$$;

create or replace function public.review_market_product(target_product_id uuid,decision text,expected_updated_at timestamptz,review_note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare item public.offerings%rowtype;
begin
 if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
 if decision not in ('approved','rejected') then raise exception '승인 또는 반려를 선택해주세요.'; end if;
 if decision='rejected' and nullif(trim(review_note),'') is null then raise exception '반려 사유를 입력해주세요.'; end if;
 select * into item from public.offerings where id=target_product_id and retired_at is null and market_review_status='pending' for update;
 if item.id is null then raise exception '처리할 상품 신청을 찾을 수 없습니다.'; end if;
 if expected_updated_at is null or item.updated_at is distinct from expected_updated_at then raise exception '신청 내용이 변경되었습니다. 다시 검토해주세요.'; end if;
 if decision='approved' then perform public.validate_market_product(to_jsonb(item)); end if;
 update public.offerings set market_review_status=decision,is_active=(decision='approved'),market_review_note=nullif(trim(review_note),''),market_reviewed_by=auth.uid(),market_reviewed_at=now(),updated_at=clock_timestamp() where id=item.id;
end;
$$;

create or replace function public.market_product_admin_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
 return jsonb_build_object(
 'pending',coalesce((select jsonb_agg(to_jsonb(r)) from (select o.*,b.business_name from public.offerings o join public.businesses b on b.id=o.business_id where b.business_type='market' and o.retired_at is null and o.market_review_status='pending' order by o.market_submitted_at limit 200) r),'[]'),
 'changes',coalesce((select jsonb_agg(to_jsonb(r)) from (select c.*,b.business_name from public.market_product_changes c join public.businesses b on b.id=c.business_id order by (c.seen_at is null) desc,c.created_at desc limit 100) r),'[]'),
 'pending_count',(select count(*) from public.offerings o join public.businesses b on b.id=o.business_id where b.business_type='market' and o.retired_at is null and o.market_review_status='pending'),
 'unread_count',(select count(*) from public.market_product_changes where seen_at is null));
end;
$$;
create or replace function public.market_product_admin_counts()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
 return jsonb_build_object('pending_count',(select count(*) from public.offerings o join public.businesses b on b.id=o.business_id where b.business_type='market' and o.retired_at is null and o.market_review_status='pending'),
 'unread_count',(select count(*) from public.market_product_changes where seen_at is null));
end;
$$;
create or replace function public.mark_market_changes_seen(target_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
 update public.market_product_changes set seen_at=now(),seen_by=auth.uid() where id=any(target_ids) and seen_at is null;
end;
$$;

-- Market products have their own lifecycle; business-profile review handles only the business.
create or replace function public.review_business_listing_request(target_request_id uuid,decision text,note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare request_row public.business_listing_review_requests%rowtype;patch jsonb;is_market boolean;
begin
 if not public.is_admin() then raise exception '관리자 권한이 필요합니다.'; end if;
 if decision not in ('approved','rejected') then raise exception '승인 또는 반려를 선택해주세요.'; end if;
 select * into request_row from public.business_listing_review_requests where id=target_request_id and status='pending' for update;
 if request_row.id is null then raise exception '처리할 심사 요청을 찾지 못했습니다.'; end if;
 select business_type='market' into is_market from public.businesses where id=request_row.business_id;
 if decision='approved' then
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
   if jsonb_array_length(request_row.proposed_offerings)>0 then perform public.save_business_offerings(request_row.business_id,request_row.proposed_offerings);
   else update public.offerings set is_active=false,updated_at=now() where business_id=request_row.business_id; end if;
  end if;
  if request_row.request_type='new_listing' then
   if not coalesce(is_market,false) then update public.offerings set is_active=true,updated_at=now() where business_id=request_row.business_id; end if;
   update public.profiles set role='partner',status='approved',updated_at=now() where id=request_row.requester_id;
  end if;
  perform public.refresh_business_highlights(request_row.business_id);
  perform public.refresh_business_nearby_distances(request_row.business_id);
 elsif request_row.request_type='new_listing' then
  update public.businesses set rejection_reason=nullif(trim(note),''),updated_at=now() where id=request_row.business_id;
 end if;
 update public.business_listing_review_requests set status=decision,review_note=nullif(trim(note),''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=target_request_id;
end;
$$;
revoke all on function public.save_market_product(uuid,jsonb,uuid,timestamptz,uuid),public.delete_market_product(uuid,timestamptz),public.review_market_product(uuid,text,timestamptz,text),public.market_product_admin_dashboard(),public.market_product_admin_counts(),public.mark_market_changes_seen(uuid[]),public.review_business_listing_request(uuid,text,text) from public,anon;
grant execute on function public.save_market_product(uuid,jsonb,uuid,timestamptz,uuid),public.delete_market_product(uuid,timestamptz),public.review_market_product(uuid,text,timestamptz,text),public.market_product_admin_dashboard(),public.market_product_admin_counts(),public.mark_market_changes_seen(uuid[]),public.review_business_listing_request(uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
