-- 적용 완료 / 일회성 복구: 가입 메타데이터에서 누락 업장 생성

insert into public.businesses (
  owner_id, business_type, business_name, representative_name, phone
)
select
  u.id,
  u.raw_user_meta_data ->> 'business_type',
  u.raw_user_meta_data ->> 'business_name',
  u.raw_user_meta_data ->> 'full_name',
  u.raw_user_meta_data ->> 'phone'
from auth.users u
join public.profiles p on p.id = u.id
where p.role = 'partner'
  and u.raw_user_meta_data ->> 'business_type' is not null
  and u.raw_user_meta_data ->> 'business_name' is not null
  and not exists (
    select 1 from public.businesses b where b.owner_id = u.id
  );
