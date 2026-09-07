-- 숙소 비공개 초안, 신규 입점 심사, 승인 후 변경 심사
create table if not exists public.business_listing_review_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  request_type text not null check (request_type in ('new_listing', 'listing_update')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  proposed_business jsonb not null default '{}'::jsonb,
  proposed_offerings jsonb not null default '[]'::jsonb,
  review_note text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists business_listing_review_one_pending_idx
on public.business_listing_review_requests(business_id) where status = 'pending';
create index if not exists business_listing_review_status_created_idx
on public.business_listing_review_requests(status, created_at desc);

drop trigger if exists business_listing_review_set_updated_at on public.business_listing_review_requests;
create trigger business_listing_review_set_updated_at before update on public.business_listing_review_requests
for each row execute procedure public.set_updated_at();

alter table public.business_listing_review_requests enable row level security;
drop policy if exists "listing_review_owner_read" on public.business_listing_review_requests;
create policy "listing_review_owner_read" on public.business_listing_review_requests
for select to authenticated using (requester_id = auth.uid() or public.is_admin());

-- 승인 대기 중인 비공개 초안도 소유자가 보완할 수 있어야 한다.
create or replace function public.owns_business(target_business_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.businesses where id = target_business_id and owner_id = auth.uid());
$$;
grant execute on function public.owns_business(uuid) to authenticated;

create or replace function public.submit_business_listing_review(
  target_business_id uuid, proposed_business jsonb, proposed_offerings jsonb, requested_type text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  request_id uuid;
  target_business public.businesses%rowtype;
begin
  select * into target_business from public.businesses where id = target_business_id;
  if target_business.id is null or (target_business.owner_id <> auth.uid() and not public.is_admin()) then
    raise exception '업장 심사 요청 권한이 없습니다.';
  end if;
  if requested_type not in ('new_listing', 'listing_update') then raise exception '올바르지 않은 심사 유형입니다.'; end if;
  if jsonb_typeof(coalesce(proposed_business, '{}'::jsonb)) <> 'object'
    or jsonb_typeof(coalesce(proposed_offerings, '[]'::jsonb)) <> 'array' then
    raise exception '심사 데이터 형식이 올바르지 않습니다.';
  end if;
  if requested_type = 'listing_update' and target_business.approval_status <> 'approved' then
    raise exception '승인된 업장만 변경 심사를 요청할 수 있습니다.';
  end if;

  update public.business_listing_review_requests
  set request_type = requested_type, proposed_business = coalesce(proposed_business, '{}'::jsonb),
      proposed_offerings = coalesce(proposed_offerings, '[]'::jsonb), review_note = null,
      reviewed_by = null, reviewed_at = null, updated_at = now()
  where business_id = target_business_id and status = 'pending'
  returning id into request_id;
  if request_id is null then
    insert into public.business_listing_review_requests
      (business_id, requester_id, request_type, proposed_business, proposed_offerings)
    values (target_business_id, target_business.owner_id, requested_type,
      coalesce(proposed_business, '{}'::jsonb), coalesce(proposed_offerings, '[]'::jsonb))
    returning id into request_id;
  end if;
  return request_id;
end;
$$;

create or replace function public.review_business_listing_request(
  target_request_id uuid, decision text, note text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  request_row public.business_listing_review_requests%rowtype;
  patch jsonb;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다.'; end if;
  if decision not in ('approved', 'rejected') then raise exception '승인 또는 반려를 선택해주세요.'; end if;
  select * into request_row from public.business_listing_review_requests
  where id = target_request_id and status = 'pending' for update;
  if request_row.id is null then raise exception '처리할 심사 요청을 찾지 못했습니다.'; end if;

  if decision = 'approved' then
    patch := request_row.proposed_business;
    update public.businesses b set
      business_name = coalesce(nullif(trim(patch->>'business_name'), ''), b.business_name),
      representative_name = coalesce(nullif(trim(patch->>'representative_name'), ''), b.representative_name),
      phone = nullif(trim(patch->>'phone'), ''), business_number = nullif(trim(patch->>'business_number'), ''),
      business_start_date = nullif(patch->>'business_start_date', '')::date,
      region = nullif(trim(patch->>'region'), ''), postal_code = nullif(trim(patch->>'postal_code'), ''),
      address = nullif(trim(patch->>'address'), ''), address_detail = nullif(trim(patch->>'address_detail'), ''),
      description = nullif(trim(patch->>'description'), ''), short_description = nullif(trim(patch->>'short_description'), ''),
      highlight_keys = case when jsonb_typeof(patch->'highlight_keys') = 'array' then array(select jsonb_array_elements_text(patch->'highlight_keys')) else b.highlight_keys end,
      facilities = case when jsonb_typeof(patch->'facilities') = 'array' then array(select jsonb_array_elements_text(patch->'facilities')) else b.facilities end,
      nearby_tags = case when jsonb_typeof(patch->'nearby_tags') = 'array' then array(select jsonb_array_elements_text(patch->'nearby_tags')) else b.nearby_tags end,
      gallery_image_urls = case when jsonb_typeof(patch->'gallery_image_urls') = 'array' then array(select jsonb_array_elements_text(patch->'gallery_image_urls')) else b.gallery_image_urls end,
      cover_image_url = nullif(trim(patch->>'cover_image_url'), ''),
      shared_bathroom_count = greatest(coalesce(nullif(patch->>'shared_bathroom_count', '')::integer, 0), 0),
      shared_bathroom_gender_separated = coalesce(nullif(patch->>'shared_bathroom_gender_separated', '')::boolean, false),
      shared_bathroom_note = nullif(trim(patch->>'shared_bathroom_note'), ''),
      shoulder_season_ranges = case when jsonb_typeof(patch->'shoulder_season_ranges') = 'array' then patch->'shoulder_season_ranges' else b.shoulder_season_ranges end,
      peak_season_ranges = case when jsonb_typeof(patch->'peak_season_ranges') = 'array' then patch->'peak_season_ranges' else b.peak_season_ranges end,
      amenity_details = case when jsonb_typeof(patch->'amenity_details') = 'array' then patch->'amenity_details' else b.amenity_details end,
      extra_fees = case when jsonb_typeof(patch->'extra_fees') = 'array' then patch->'extra_fees' else b.extra_fees end,
      latitude = nullif(patch->>'latitude', '')::numeric, longitude = nullif(patch->>'longitude', '')::numeric,
      location_verified_at = nullif(patch->>'location_verified_at', '')::timestamptz,
      approval_status = case when request_row.request_type = 'new_listing' then 'approved' else b.approval_status end,
      rejection_reason = null, updated_at = now()
    where b.id = request_row.business_id;

    if jsonb_array_length(request_row.proposed_offerings) > 0 then
      perform public.save_business_offerings(request_row.business_id, request_row.proposed_offerings);
    else
      update public.offerings set is_active = false, updated_at = now() where business_id = request_row.business_id;
    end if;
    if request_row.request_type = 'new_listing' then
      update public.offerings set is_active = true, updated_at = now() where business_id = request_row.business_id;
      update public.profiles set role = 'partner', status = 'approved', updated_at = now() where id = request_row.requester_id;
    end if;
    perform public.refresh_business_highlights(request_row.business_id);
    perform public.refresh_business_nearby_distances(request_row.business_id);
  elsif request_row.request_type = 'new_listing' then
    update public.businesses set rejection_reason = nullif(trim(note), ''), updated_at = now()
    where id = request_row.business_id;
  end if;

  update public.business_listing_review_requests
  set status = decision, review_note = nullif(trim(note), ''), reviewed_by = auth.uid(),
      reviewed_at = now(), updated_at = now()
  where id = target_request_id;
end;
$$;

revoke all on function public.submit_business_listing_review(uuid,jsonb,jsonb,text) from public;
revoke all on function public.review_business_listing_request(uuid,text,text) from public;
grant execute on function public.submit_business_listing_review(uuid,jsonb,jsonb,text) to authenticated;
grant execute on function public.review_business_listing_request(uuid,text,text) to authenticated;
grant select on public.business_listing_review_requests to authenticated;
grant select (import_job_id) on public.businesses to authenticated;
