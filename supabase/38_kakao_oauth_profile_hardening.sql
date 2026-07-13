-- Make OAuth signups, including Kakao, land as approved user accounts while
-- preserving the partner signup path that passes business metadata.

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
  display_name text;
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

  display_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'name', ''),
    nullif(new.raw_user_meta_data ->> 'user_name', ''),
    nullif(new.raw_user_meta_data ->> 'preferred_username', ''),
    nullif(new.raw_user_meta_data ->> 'nickname', ''),
    nullif(new.raw_user_meta_data #>> '{kakao_account,profile,nickname}', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'User'
  );

  insert into public.profiles (
    id, email, full_name, phone, role, status
  )
  values (
    new.id,
    new.email,
    display_name,
    new.raw_user_meta_data ->> 'phone',
    assigned_role,
    assigned_status
  )
  on conflict (id) do update
  set email = excluded.email,
      full_name = coalesce(public.profiles.full_name, excluded.full_name),
      phone = coalesce(public.profiles.phone, excluded.phone),
      updated_at = now();

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
      coalesce(display_name, 'Representative'),
      new.raw_user_meta_data ->> 'phone',
      'pending'
    )
    on conflict do nothing;
  end if;

  return new;
end;
$$;

update public.profiles p
set full_name = coalesce(
      nullif(u.raw_user_meta_data ->> 'full_name', ''),
      nullif(u.raw_user_meta_data ->> 'name', ''),
      nullif(u.raw_user_meta_data ->> 'user_name', ''),
      nullif(u.raw_user_meta_data ->> 'preferred_username', ''),
      nullif(u.raw_user_meta_data ->> 'nickname', ''),
      nullif(u.raw_user_meta_data #>> '{kakao_account,profile,nickname}', ''),
      nullif(split_part(coalesce(u.email, p.email, ''), '@', 1), ''),
      'User'
    ),
    updated_at = now()
from auth.users u
where p.id = u.id
  and nullif(p.full_name, '') is null;
