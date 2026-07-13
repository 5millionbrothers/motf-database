-- 파트너 프로필과 업장 승인 상태 동기화

-- 업장을 가진 비관리자 계정은 업장의 심사 상태를 기준으로 파트너 상태를 맞춘다.
-- 예: profile=user/approved, business=pending 이던 계정은 partner/pending으로 복구된다.
update public.profiles p
set role = 'partner',
    status = b.approval_status
from public.businesses b
where b.owner_id = p.id
  and p.role <> 'admin'
  and b.approval_status in ('pending', 'approved', 'rejected', 'suspended')
  and (p.role <> 'partner' or p.status is distinct from b.approval_status);
