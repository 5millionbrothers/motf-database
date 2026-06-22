-- 파트너 역할 복구와 승인 함수 보강

-- 파트너 가입 과정에서 업장은 생성됐지만 프로필이 일반 이용자로 남은 계정을 복구한다.
update public.profiles p
set role = 'partner'
where p.role = 'user'
  and exists (
    select 1 from public.businesses b where b.owner_id = p.id
  );

-- 관리자가 업장 가입을 승인할 때 프로필 역할도 partner로 확정한다.
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

  if not exists (
    select 1 from public.businesses where owner_id = target_user_id
  ) then
    raise exception '연결된 업장 정보를 찾을 수 없습니다.';
  end if;

  update public.profiles
  set role = 'partner',
      status = decision
  where id = target_user_id;

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
grant execute on function public.review_partner_application(uuid, text, text) to authenticated;
