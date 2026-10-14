-- Stage 1: username login on existing UUIDs, optional contact email and adult purchase verification.
begin;

do $$
begin
  if exists(select 1 from public.profiles where username is not null
    group by lower(trim(username)) having count(*) > 1) then
    raise exception '기존 아이디에 대소문자 중복이 있습니다. 기존 계정을 확인한 뒤 다시 적용해주세요.';
  end if;
end;
$$;

create unique index if not exists profiles_username_casefold_unique
on public.profiles (lower(trim(username))) where username is not null;
revoke update (username) on public.profiles from authenticated;

create or replace function public.assign_login_username(target_user_id uuid, target_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare current_username text; normalized text := lower(trim(target_username));
begin
  if normalized is null or normalized !~ '^[a-z][a-z0-9_]{3,23}$' then
    raise exception '아이디는 영문으로 시작하는 영문 소문자·숫자·밑줄 4~24자리로 입력해주세요.';
  end if;
  select username into current_username from public.profiles
  where id = target_user_id and withdrawal_processed_at is null and status in ('approved','pending') for update;
  if not found then raise exception '사용 가능한 계정을 찾지 못했습니다.'; end if;
  if current_username is not null and lower(trim(current_username)) <> normalized then
    raise exception '이미 설정한 아이디는 변경할 수 없습니다.';
  end if;
  update public.profiles set username = normalized where id = target_user_id;
end;
$$;
revoke all on function public.assign_login_username(uuid,text) from public;
grant execute on function public.assign_login_username(uuid,text) to service_role;

create table if not exists public.login_email_aliases (
  email text primary key, user_id uuid not null references public.profiles(id) on delete cascade
);
alter table public.login_email_aliases enable row level security;
revoke all on public.login_email_aliases from anon, authenticated;
grant select, insert, update, delete on public.login_email_aliases to service_role;

create or replace function public.resolve_account_login(target_identifier text)
returns table(id uuid, username text, status text, identity_ci_hash text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.username, p.status, p.identity_ci_hash
  from public.profiles p join auth.users u on u.id = p.id
  where p.withdrawal_processed_at is null
    and case when position('@' in target_identifier) > 0
      then (lower(u.email) = lower(trim(target_identifier))
        and u.email not like '%@accounts.motf.invalid'
        and not exists(select 1 from public.login_email_aliases reserved
          where reserved.email = lower(trim(target_identifier))))
        or exists(select 1 from public.login_email_aliases a
          where a.user_id = p.id and a.email = lower(trim(target_identifier)))
      else lower(trim(p.username)) = lower(trim(target_identifier)) end
  limit 1;
$$;
revoke all on function public.resolve_account_login(text) from public;
grant execute on function public.resolve_account_login(text) to service_role;

create table if not exists public.account_request_limits (
  bucket text primary key, window_start timestamptz not null, attempts integer not null
);
alter table public.account_request_limits enable row level security;
revoke all on public.account_request_limits from anon, authenticated;
grant select, insert, update, delete on public.account_request_limits to service_role;
create or replace function public.consume_account_request_limit(target_bucket text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_total integer;
begin
  delete from public.account_request_limits where window_start < now() - interval '1 day';
  insert into public.account_request_limits(bucket, window_start, attempts) values(target_bucket, now(), 1)
  on conflict(bucket) do update set
    attempts = case when public.account_request_limits.window_start < now() - interval '10 minutes'
      then 1 else public.account_request_limits.attempts + 1 end,
    window_start = case when public.account_request_limits.window_start < now() - interval '10 minutes'
      then now() else public.account_request_limits.window_start end
  returning attempts into attempt_total;
  return attempt_total <= 30;
end;
$$;
revoke all on function public.consume_account_request_limit(text) from public;
grant execute on function public.consume_account_request_limit(text) to service_role;

alter table public.profiles add column if not exists adult_verified_until timestamptz;
alter table public.profiles add column if not exists adult_verification_source text;
alter table public.profiles add column if not exists contact_email_verified_at timestamptz;
alter table public.profiles add column if not exists terms_accepted_at timestamptz;
alter table public.identity_verification_sessions drop constraint if exists identity_verification_sessions_purpose_check;
alter table public.identity_verification_sessions add constraint identity_verification_sessions_purpose_check
check (purpose in ('signup','owner_signup','password_reset','profile_upgrade','adult_purchase'));

create or replace function public.current_user_is_adult()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'approved'
      and p.identity_verified_at is not null
      and p.adult_verification_source = 'adult_purchase'
      and p.adult_verified_at is not null and p.adult_verified_at <= now()
      and p.adult_verified_until > now()
      and p.birth_date <= current_date - interval '19 years');
$$;

create or replace function public.enforce_verified_payment_customer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.customer_id is not null and new.kind in ('stay','market','extra_charge')
    and not exists(select 1 from public.profiles p where p.id = new.customer_id and p.status = 'approved')
  then raise exception '현재 결제할 수 없는 계정입니다.'; end if;
  return new;
end;
$$;

create or replace function public.complete_basic_user_profile(
  profile_name text, profile_phone text, profile_organization text, terms_accepted boolean
)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare result public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if terms_accepted is not true then raise exception '필수 약관에 동의해주세요.'; end if;
  if nullif(trim(profile_name),'') is null or coalesce(length(regexp_replace(profile_phone,'[^0-9]','','g')),0) not between 9 and 15 then
    raise exception '이름과 연락처를 확인해주세요.';
  end if;
  update public.profiles p set
    full_name = case when p.identity_verified_at is null then left(trim(profile_name),80) else p.full_name end,
    phone = regexp_replace(profile_phone,'[^0-9]','','g'),
    organization = nullif(left(trim(profile_organization),80),''),
    profile_completed_at = now(),
    terms_accepted_at = coalesce(p.terms_accepted_at, now())
  where p.id = auth.uid() and p.role = 'user' and p.status = 'approved'
  returning * into result;
  if result.id is null then raise exception '사용 가능한 계정을 찾지 못했습니다.'; end if;
  return result;
end;
$$;
revoke all on function public.complete_basic_user_profile(text,text,text,boolean) from public;
grant execute on function public.complete_basic_user_profile(text,text,text,boolean) to authenticated;

update public.platform_settings set setting_value = setting_value || jsonb_build_object(
  'required_for_signup',true, 'required_for_kakao_signup',false,
  'required_for_checkout',false, 'adult_verification_validity_years',1
), description = '일반 가입 본인확인 1회, 카카오 간편가입, 주류 주문 별도 성인확인 1년' where setting_key = 'identity';

create or replace function public.preview_checkout_benefits(
  target_original_amount integer,
  target_transaction_kind text,
  target_business_id uuid default null,
  requested_points integer default 0,
  requested_coupon_code text default null
)
returns table(
  original_amount integer,
  available_points integer,
  applied_points integer,
  applied_coupon_discount integer,
  payable_amount integer,
  coupon_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  account_balance integer := 0;
  held_points integer := 0;
  usable_points integer := 0;
  point_amount integer := 0;
  coupon_amount integer := 0;
  minimum_external integer := 100;
  selected_coupon public.coupons%rowtype;
  prior_uses integer := 0;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'approved' 
  ) then
    raise exception '현재 결제할 수 없는 계정입니다.';
  end if;
  if target_original_amount is null or target_original_amount <= 0 then raise exception '주문 금액을 확인해주세요.'; end if;
  if target_transaction_kind not in ('stay', 'market') then raise exception '결제 종류를 확인해주세요.'; end if;

  minimum_external := coalesce((
    select (setting_value ->> 'minimum_external_amount')::integer
    from public.platform_settings where setting_key = 'payment'
  ), 100);

  select coalesce((
    select a.balance
    from public.point_accounts a
    where a.user_id = auth.uid()
  ), 0) into account_balance;
  select coalesce(sum(h.amount), 0) into held_points
  from public.point_holds h
  where h.user_id = auth.uid() and h.status = 'held' and h.expires_at > now();
  usable_points := greatest(account_balance - held_points, 0);

  if nullif(upper(trim(requested_coupon_code)), '') is not null then
    select * into selected_coupon
    from public.coupons c
    where upper(c.code) = upper(trim(requested_coupon_code))
      and c.is_active
      and now() between c.starts_at and c.ends_at
      and c.minimum_order_amount <= target_original_amount
      and c.applies_to in ('all', target_transaction_kind)
      and (c.business_id is null or c.business_id = target_business_id);
    if selected_coupon.id is null then raise exception '사용할 수 없는 할인코드입니다.'; end if;

    select count(*) into prior_uses
    from public.coupon_redemptions r
    where r.coupon_id = selected_coupon.id
      and r.user_id = auth.uid()
      and r.status in ('reserved', 'used');
    if prior_uses >= selected_coupon.per_user_limit then raise exception '할인코드 사용 가능 횟수를 초과했습니다.'; end if;
    if selected_coupon.total_usage_limit is not null and (
      select count(*) from public.coupon_redemptions r
      where r.coupon_id = selected_coupon.id and r.status in ('reserved', 'used')
    ) >= selected_coupon.total_usage_limit then
      raise exception '할인코드가 모두 소진되었습니다.';
    end if;

    coupon_amount := case when selected_coupon.discount_type = 'fixed'
      then selected_coupon.discount_value::integer
      else floor(target_original_amount * selected_coupon.discount_value / 100)::integer end;
    coupon_amount := least(
      coupon_amount,
      coalesce(selected_coupon.maximum_discount, coupon_amount),
      greatest(target_original_amount - minimum_external, 0)
    );
    if coupon_amount <= 0 then raise exception '이 주문에 적용할 할인금액이 없습니다.'; end if;
  end if;

  point_amount := least(
    greatest(coalesce(requested_points, 0), 0),
    usable_points,
    greatest(target_original_amount - coupon_amount - minimum_external, 0)
  );

  return query select
    target_original_amount,
    usable_points,
    point_amount,
    coupon_amount,
    target_original_amount - coupon_amount - point_amount,
    selected_coupon.name;
end;
$$;

revoke all on function public.preview_checkout_benefits(integer,text,uuid,integer,text) from public;
grant execute on function public.preview_checkout_benefits(integer,text,uuid,integer,text) to authenticated;

commit;
