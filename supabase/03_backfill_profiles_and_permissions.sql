-- 적용 완료 / 일회성 복구: 누락 프로필 생성 및 최소 권한 부여

insert into public.profiles (id, email, full_name, phone, role, status)
select
  u.id,
  u.email,
  u.raw_user_meta_data ->> 'full_name',
  u.raw_user_meta_data ->> 'phone',
  'partner',
  'pending'
from auth.users u
where not exists (
  select 1 from public.profiles p where p.id = u.id
);

grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant select, insert on public.businesses to authenticated;
