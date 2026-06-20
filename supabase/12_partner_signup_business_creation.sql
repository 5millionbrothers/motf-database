-- 파트너 가입 시 profiles와 함께 승인 대기 businesses 행을 생성합니다.
-- 일반 이용자 및 OAuth 가입은 기존처럼 user / approved로 생성됩니다.

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
  requested_account_type := coalesce(new.raw_user_meta_data ->> 'account_type', '');
  requested_business_type := coalesce(new.raw_user_meta_data ->> 'business_type', '');

  if requested_account_type = 'partner'
     or requested_business_type in ('stay', 'market') then
    assigned_role := 'partner';
    assigned_status := 'pending';
  else
    assigned_role := 'user';
    assigned_status := 'approved';
  end if;

  insert into public.profiles (
    id, email, full_name, phone, role, status
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

  if assigned_role = 'partner'
     and requested_business_type in ('stay', 'market')
     and nullif(new.raw_user_meta_data ->> 'business_name', '') is not null then
    insert into public.businesses (
      owner_id,
      business_type,
      business_name,
      representative_name,
      phone,
      approval_status
    )
    values (
      new.id,
      requested_business_type,
      new.raw_user_meta_data ->> 'business_name',
      coalesce(new.raw_user_meta_data ->> 'full_name', '대표자'),
      new.raw_user_meta_data ->> 'phone',
      'pending'
    );
  end if;

  return new;
end;
$$;

-- 기존 파트너 중 업장 행이 누락된 계정 복구
insert into public.businesses (
  owner_id,
  business_type,
  business_name,
  representative_name,
  phone,
  approval_status
)
select
  u.id,
  u.raw_user_meta_data ->> 'business_type',
  u.raw_user_meta_data ->> 'business_name',
  coalesce(u.raw_user_meta_data ->> 'full_name', '대표자'),
  u.raw_user_meta_data ->> 'phone',
  p.status
from auth.users u
join public.profiles p on p.id = u.id
where p.role = 'partner'
  and u.raw_user_meta_data ->> 'business_type' in ('stay', 'market')
  and nullif(u.raw_user_meta_data ->> 'business_name', '') is not null
  and not exists (
    select 1 from public.businesses b where b.owner_id = u.id
  );
