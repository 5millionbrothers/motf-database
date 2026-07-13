-- 운영진 회원·파트너 계정 상태 관리
-- 관리자는 이용자와 파트너를 승인·정지·해제할 수 있습니다.

create or replace function public.set_account_status(
  target_user_id uuid,
  new_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_role text;
begin
  if not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  if new_status not in ('pending', 'approved', 'rejected', 'suspended') then
    raise exception '올바르지 않은 계정 상태입니다.';
  end if;

  if target_user_id = auth.uid() and new_status <> 'approved' then
    raise exception '현재 로그인한 관리자 본인의 계정은 정지할 수 없습니다.';
  end if;

  select role into target_role
  from public.profiles
  where id = target_user_id;

  if target_role is null then
    raise exception '대상 회원을 찾을 수 없습니다.';
  end if;

  update public.profiles
  set status = new_status
  where id = target_user_id;

  if target_role = 'partner' then
    update public.businesses
    set
      approval_status = new_status,
      rejection_reason = case
        when new_status = 'rejected' then coalesce(rejection_reason, '운영진 검토 결과 반려')
        else null
      end
    where owner_id = target_user_id;
  end if;
end;
$$;

revoke all on function public.set_account_status(uuid, text) from public;
grant execute on function public.set_account_status(uuid, text) to authenticated;
