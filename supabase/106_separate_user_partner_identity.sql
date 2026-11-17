-- Separate signup identities without moving existing user IDs or transaction history.
begin;
alter table public.profiles add column if not exists account_type text;
update public.profiles set account_type=case when role in ('partner','admin') then 'partner' else 'user' end where account_type is null;
alter table public.profiles alter column account_type set default 'user';
alter table public.profiles alter column account_type set not null;
alter table public.profiles drop constraint if exists profiles_account_type_check;
alter table public.profiles add constraint profiles_account_type_check check(account_type in ('user','partner'));

create or replace function public.guard_profile_account_type()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' then
    new.account_type=case when new.role in ('partner','admin') then 'partner' else 'user' end;
  elsif new.account_type is distinct from old.account_type
    and coalesce(auth.role(),'')<>'service_role'
    and not (auth.uid() is null and current_user in ('postgres','supabase_admin')) then
    raise exception '계정 종류는 직접 변경할 수 없습니다.' using errcode='42501';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_profile_account_type on public.profiles;
create trigger guard_profile_account_type before insert or update of account_type on public.profiles
for each row execute function public.guard_profile_account_type();
revoke update(account_type) on public.profiles from authenticated;

drop index if exists public.profiles_active_identity_ci_unique;
create unique index if not exists profiles_active_identity_ci_per_site_unique
on public.profiles(account_type,identity_ci_hash)
where identity_ci_hash is not null and withdrawal_processed_at is null;

-- Usernames remain globally unique, preserving staff invitations and old email logins.
create or replace function public.resolve_account_login_for_site(target_identifier text,target_account_type text)
returns table(id uuid,username text,status text,identity_ci_hash text,account_type text)
language sql stable security definer set search_path='' as $$
  select p.id,p.username,p.status,p.identity_ci_hash,p.account_type
  from public.resolve_account_login(target_identifier) a join public.profiles p on p.id=a.id
  where (target_account_type='user' and p.account_type='user')
    or (target_account_type='partner' and (p.account_type='partner'
      or exists(select 1 from public.business_members m where m.user_id=p.id and m.status='active')
      or exists(select 1 from public.businesses b where b.owner_id=p.id)));
$$;
revoke all on function public.resolve_account_login_for_site(text,text) from public,anon,authenticated;
grant execute on function public.resolve_account_login_for_site(text,text) to service_role;

create or replace function public.complete_identity_signup_profile(
  target_user_id uuid,target_email text,target_full_name text,target_phone text,target_birth_date date,
  target_ci_hash text,target_verified_at timestamptz,target_is_adult boolean,target_account_type text default 'user'
) returns void language plpgsql security definer set search_path='' as $$
begin
  if target_account_type is null or target_account_type not in ('user','partner') then raise exception '계정 종류를 확인해주세요.'; end if;
  if exists(select 1 from public.profiles p where p.id=target_user_id and p.account_type<>target_account_type) then
    raise exception '기존 계정의 종류를 바꾸지 말고 별도 계정으로 가입해주세요.';
  end if;
  insert into public.profiles(id,email,full_name,phone,birth_date,role,status,account_type,
    identity_provider,identity_ci_hash,identity_verified_at,adult_verified_at,password_set_at)
  values(target_user_id,lower(trim(target_email)),nullif(trim(target_full_name),''),nullif(regexp_replace(target_phone,'[^0-9]','','g'),''),target_birth_date,
    case when target_account_type='partner' then 'partner' else 'user' end,
    case when target_account_type='partner' then 'pending' else 'approved' end,target_account_type,
    'kcp',target_ci_hash,target_verified_at,case when target_is_adult then target_verified_at else null end,now())
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,
    birth_date=excluded.birth_date,role=excluded.role,status=excluded.status,identity_provider=excluded.identity_provider,
    identity_ci_hash=excluded.identity_ci_hash,identity_verified_at=excluded.identity_verified_at,
    adult_verified_at=excluded.adult_verified_at,password_set_at=coalesce(public.profiles.password_set_at,excluded.password_set_at),updated_at=now();
end;
$$;
revoke all on function public.complete_identity_signup_profile(uuid,text,text,text,date,text,timestamptz,boolean,text) from public,anon,authenticated;
grant execute on function public.complete_identity_signup_profile(uuid,text,text,text,date,text,timestamptz,boolean,text) to service_role;
commit;
