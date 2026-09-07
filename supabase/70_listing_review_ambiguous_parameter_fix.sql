-- 심사 요청 RPC의 JSON 인자명과 테이블 컬럼명이 같을 때 발생하는 모호성 오류 수정
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
  if jsonb_typeof(coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb)) <> 'object'
    or jsonb_typeof(coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb)) <> 'array' then
    raise exception '심사 데이터 형식이 올바르지 않습니다.';
  end if;
  if requested_type = 'listing_update' and target_business.approval_status <> 'approved' then
    raise exception '승인된 업장만 변경 심사를 요청할 수 있습니다.';
  end if;

  update public.business_listing_review_requests as review
  set request_type = requested_type,
      proposed_business = coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb),
      proposed_offerings = coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb),
      review_note = null, reviewed_by = null, reviewed_at = null, updated_at = now()
  where review.business_id = target_business_id and review.status = 'pending'
  returning review.id into request_id;
  if request_id is null then
    insert into public.business_listing_review_requests
      (business_id, requester_id, request_type, proposed_business, proposed_offerings)
    values (target_business_id, target_business.owner_id, requested_type,
      coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb),
      coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb))
    returning id into request_id;
  end if;
  return request_id;
end;
$$;

revoke all on function public.submit_business_listing_review(uuid,jsonb,jsonb,text) from public;
grant execute on function public.submit_business_listing_review(uuid,jsonb,jsonb,text) to authenticated;
