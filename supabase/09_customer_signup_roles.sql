-- 적용 전 검토 필요: 이용자 사이트 로그인 연결용 가입 역할 분리
-- 일반 이용자 및 OAuth 가입: user / approved
-- 사업자 유형(stay 또는 market)이 포함된 가입: partner / pending
-- admin 역할은 이 함수로 절대 생성하지 않음

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_account_type text;
  requested_business_type text;
  assigned_role text;
  assigned_status text;
begin
  requested_account_type := coalesce(
    new.raw_user_meta_data ->> 'account_type',
    ''
  );
  requested_business_type := coalesce(
    new.raw_user_meta_data ->> 'business_type',
    ''
  );

  if requested_account_type = 'partner'
     or requested_business_type in ('stay', 'market') then
    assigned_role := 'partner';
    assigned_status := 'pending';
  else
    assigned_role := 'user';
    assigned_status := 'approved';
  end if;

  insert into public.profiles (
    id,
    email,
    full_name,
    phone,
    role,
    status
  )
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'user_name'
    ),
    new.raw_user_meta_data ->> 'phone',
    assigned_role,
    assigned_status
  );

  return new;
end;
$$;
