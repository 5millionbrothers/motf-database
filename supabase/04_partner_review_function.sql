-- 적용 완료: 운영팀의 파트너 가입 승인·거절 함수

create or replace function public.review_partner_application(
  target_user_id uuid,
  decision text,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  if decision not in ('approved', 'rejected') then
    raise exception '올바르지 않은 처리 상태입니다.';
  end if;

  update public.profiles set status = decision where id = target_user_id;
  if not found then
    raise exception '대상 회원을 찾을 수 없습니다.';
  end if;

  update public.businesses
  set approval_status = decision,
      rejection_reason = case when decision = 'rejected' then reason else null end
  where owner_id = target_user_id;
end;
$$;

revoke all on function public.review_partner_application(uuid, text, text) from public;
grant execute on function public.review_partner_application(uuid, text, text)
to authenticated;
