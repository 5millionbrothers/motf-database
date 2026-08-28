-- moTF launch foundation: Toss Payments, KCP identity, points/coupons and settlement funding.
-- Historical PortOne rows remain readable. New checkout intents use provider='toss'.

create table if not exists public.platform_settings (
  setting_key text primary key,
  setting_value jsonb not null default '{}'::jsonb,
  description text,
  is_public boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists platform_settings_set_updated_at on public.platform_settings;
create trigger platform_settings_set_updated_at before update on public.platform_settings
for each row execute procedure public.set_updated_at();

alter table public.platform_settings enable row level security;
drop policy if exists "platform_settings_public_read" on public.platform_settings;
create policy "platform_settings_public_read" on public.platform_settings
for select to anon, authenticated using (is_public or public.is_admin());
drop policy if exists "platform_settings_admin_all" on public.platform_settings;
create policy "platform_settings_admin_all" on public.platform_settings
for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.platform_settings to anon, authenticated;
grant insert, update, delete on public.platform_settings to authenticated;

insert into public.platform_settings (setting_key, setting_value, description, is_public)
values
  ('payment', '{"provider":"toss","enabled_methods":["CARD","TRANSFER"],"future_methods":["VIRTUAL_ACCOUNT"],"currency":"KRW","minimum_external_amount":100}'::jsonb, '토스 결제수단과 최소 외부 결제금액', true),
  ('commission', '{"stay_rate":0.035,"market_rate":0.035}'::jsonb, '베타 기본 중개 수수료. 확정 전 운영자 화면에서 변경', false),
  ('identity', '{"provider":"kcp","required_for_signup":false,"required_for_owner_signup":false}'::jsonb, 'KCP 운영키 적용 후 required 값을 true로 전환', true),
  ('social', '{"instagram_url":""}'::jsonb, '공식 소셜 링크', true)
on conflict (setting_key) do nothing;

alter table public.profiles
  add column if not exists birth_date date,
  add column if not exists identity_provider text,
  add column if not exists identity_ci_hash text,
  add column if not exists identity_verified_at timestamptz,
  add column if not exists adult_verified_at timestamptz,
  add column if not exists password_set_at timestamptz,
  add column if not exists profile_completed_at timestamptz;

create unique index if not exists profiles_active_identity_ci_unique
on public.profiles(identity_ci_hash)
where identity_ci_hash is not null and withdrawal_processed_at is null;

create table if not exists public.identity_verification_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  purpose text not null check (purpose in ('signup','owner_signup','password_reset','profile_upgrade')),
  provider text not null default 'kcp' check (provider in ('kcp')),
  state_hash text not null unique,
  requested_email text,
  request_context jsonb not null default '{}'::jsonb,
  provider_transaction_id text unique,
  status text not null default 'created' check (status in ('created','pending','verified','consumed','failed','expired')),
  verified_name text,
  verified_phone text,
  verified_birth_date date,
  verified_ci_hash text,
  verified_di_hash text,
  is_adult boolean,
  provider_response jsonb,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  verified_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.identity_verification_sessions
  add column if not exists requested_email text,
  add column if not exists request_context jsonb not null default '{}'::jsonb;

drop trigger if exists identity_verification_sessions_set_updated_at on public.identity_verification_sessions;
create trigger identity_verification_sessions_set_updated_at before update on public.identity_verification_sessions
for each row execute procedure public.set_updated_at();
alter table public.identity_verification_sessions enable row level security;
grant select, insert, update on public.identity_verification_sessions to service_role;

create or replace function public.current_user_is_adult()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.identity_verified_at is not null
      and p.adult_verified_at is not null
      and p.birth_date <= current_date - interval '19 years'
  );
$$;
revoke all on function public.current_user_is_adult() from public;
grant execute on function public.current_user_is_adult() to authenticated;

alter table public.businesses
  add column if not exists business_start_date date,
  add column if not exists commission_rate_override numeric(6,5)
    check (commission_rate_override is null or commission_rate_override between 0 and 1),
  add column if not exists display_order integer not null default 1000,
  add column if not exists discovery_weight integer not null default 100 check (discovery_weight between 0 and 10000),
  add column if not exists is_featured boolean not null default false,
  add column if not exists onboarding_status text not null default 'draft',
  add column if not exists onboarding_note text;

alter table public.businesses drop constraint if exists businesses_onboarding_status_check;
alter table public.businesses add constraint businesses_onboarding_status_check
check (onboarding_status in ('draft','identity_pending','documents_pending','review','approved','rejected'));

create table if not exists public.business_verification_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  document_type text not null check (document_type in ('business_registration','representative_identity','bank_account','lodging_license','liquor_license','other')),
  storage_path text not null,
  review_status text not null default 'pending' check (review_status in ('pending','approved','rejected')),
  review_note text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.business_verification_documents enable row level security;
drop policy if exists "business_documents_participant_read" on public.business_verification_documents;
create policy "business_documents_participant_read" on public.business_verification_documents
for select to authenticated using (public.owns_business(business_id) or public.is_admin());
drop policy if exists "business_documents_owner_insert" on public.business_verification_documents;
create policy "business_documents_owner_insert" on public.business_verification_documents
for insert to authenticated with check (public.owns_business(business_id) or public.is_admin());
drop policy if exists "business_documents_admin_update" on public.business_verification_documents;
create policy "business_documents_admin_update" on public.business_verification_documents
for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update on public.business_verification_documents to authenticated;

alter table public.payment_intents
  add column if not exists original_amount integer,
  add column if not exists customer_paid_amount integer,
  add column if not exists points_used integer not null default 0,
  add column if not exists coupon_discount integer not null default 0,
  add column if not exists platform_discount integer not null default 0,
  add column if not exists payment_method text,
  add column if not exists provider_status text,
  add column if not exists provider_payment_id text,
  add column if not exists currency text not null default 'KRW';

update public.payment_intents
set original_amount = coalesce(original_amount, amount),
    customer_paid_amount = coalesce(customer_paid_amount, amount)
where original_amount is null or customer_paid_amount is null;

alter table public.payment_intents alter column provider set default 'toss';
alter table public.payment_intents drop constraint if exists payment_intents_status_check;
alter table public.payment_intents add constraint payment_intents_status_check check (status in (
  'prepared','ready','in_progress','waiting_for_deposit','virtual_account_issued',
  'confirmed','done','cancelled','partial_cancelled','failed','expired','aborted'
));

alter table public.reservations
  add column if not exists original_amount integer,
  add column if not exists customer_paid_amount integer,
  add column if not exists points_used integer not null default 0,
  add column if not exists coupon_discount integer not null default 0,
  add column if not exists payment_method text;

alter table public.market_orders
  add column if not exists original_amount integer,
  add column if not exists customer_paid_amount integer,
  add column if not exists points_used integer not null default 0,
  add column if not exists coupon_discount integer not null default 0,
  add column if not exists payment_method text;

create table if not exists public.point_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  balance integer not null default 0 check (balance >= 0),
  lifetime_earned integer not null default 0 check (lifetime_earned >= 0),
  lifetime_used integer not null default 0 check (lifetime_used >= 0),
  updated_at timestamptz not null default now()
);

insert into public.point_accounts(user_id)
select id from public.profiles on conflict (user_id) do nothing;

create or replace function public.create_point_account_for_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.point_accounts(user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists profile_create_point_account on public.profiles;
create trigger profile_create_point_account after insert on public.profiles
for each row execute function public.create_point_account_for_profile();

create table if not exists public.point_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check (amount <> 0),
  balance_after integer not null check (balance_after >= 0),
  entry_type text not null check (entry_type in ('earn','use','refund','expire','admin_adjust')),
  reason text not null,
  source_type text,
  source_id uuid,
  expires_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists point_ledger_user_created_idx on public.point_ledger(user_id, created_at desc);
create unique index if not exists point_ledger_source_unique_idx
on public.point_ledger(user_id, source_type, source_id, entry_type)
where source_id is not null;

create table if not exists public.point_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  campaign_kind text not null default 'cashback' check (campaign_kind in ('cashback','signup','affiliation','manual')),
  transaction_kind text not null default 'all' check (transaction_kind in ('all','stay','market')),
  reward_rate numeric(7,6) not null default 0 check (reward_rate between 0 and 1),
  fixed_points integer not null default 0 check (fixed_points >= 0),
  max_points integer,
  minimum_amount integer not null default 0,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_active boolean not null default true,
  priority integer not null default 100,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  discount_type text not null check (discount_type in ('fixed','percent')),
  discount_value numeric(12,4) not null check (discount_value > 0),
  maximum_discount integer,
  minimum_order_amount integer not null default 0,
  applies_to text not null default 'all' check (applies_to in ('all','stay','market')),
  business_id uuid references public.businesses(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  total_usage_limit integer,
  per_user_limit integer not null default 1,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create unique index if not exists coupons_code_upper_unique on public.coupons(upper(code));

create table if not exists public.coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.coupons(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete cascade,
  payment_intent_id uuid not null references public.payment_intents(id) on delete cascade,
  discount_amount integer not null check (discount_amount > 0),
  status text not null default 'reserved' check (status in ('reserved','used','released')),
  used_at timestamptz,
  created_at timestamptz not null default now(),
  unique(coupon_id, user_id, payment_intent_id)
);

create table if not exists public.point_holds (
  id uuid primary key default gen_random_uuid(),
  payment_intent_id uuid not null unique references public.payment_intents(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check (amount > 0),
  status text not null default 'held' check (status in ('held','consumed','released')),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  released_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.market_inventory_holds (
  payment_intent_id uuid not null references public.payment_intents(id) on delete cascade,
  offering_id uuid not null references public.offerings(id) on delete cascade,
  quantity integer not null check (quantity > 0),
  expires_at timestamptz not null,
  status text not null default 'held' check (status in ('held','consumed','released')),
  primary key(payment_intent_id, offering_id)
);

alter table public.point_accounts enable row level security;
alter table public.point_ledger enable row level security;
alter table public.point_campaigns enable row level security;
alter table public.coupons enable row level security;
alter table public.coupon_redemptions enable row level security;
alter table public.point_holds enable row level security;
alter table public.market_inventory_holds enable row level security;

drop policy if exists "point_accounts_read_owner_admin" on public.point_accounts;
create policy "point_accounts_read_owner_admin" on public.point_accounts for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists "point_ledger_read_owner_admin" on public.point_ledger;
create policy "point_ledger_read_owner_admin" on public.point_ledger for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists "point_campaigns_public_read" on public.point_campaigns;
create policy "point_campaigns_public_read" on public.point_campaigns for select to anon, authenticated
using (is_active or public.is_admin());
drop policy if exists "point_campaigns_admin_all" on public.point_campaigns;
create policy "point_campaigns_admin_all" on public.point_campaigns for all to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists "coupons_admin_all" on public.coupons;
create policy "coupons_admin_all" on public.coupons for all to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists "coupon_redemptions_read_owner_admin" on public.coupon_redemptions;
create policy "coupon_redemptions_read_owner_admin" on public.coupon_redemptions for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists "point_holds_read_owner_admin" on public.point_holds;
create policy "point_holds_read_owner_admin" on public.point_holds for select to authenticated
using (user_id = auth.uid() or public.is_admin());

grant select on public.point_accounts, public.point_ledger, public.point_campaigns, public.coupon_redemptions, public.point_holds to authenticated;
grant select on public.point_campaigns to anon;
grant select, insert, update, delete on public.point_campaigns, public.coupons to authenticated;

create or replace function public.admin_adjust_points(
  target_user_id uuid,
  adjustment integer,
  adjustment_reason text
)
returns integer language plpgsql security definer set search_path = '' as $$
declare new_balance integer;
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  if adjustment = 0 or nullif(trim(adjustment_reason),'') is null then raise exception '포인트와 사유를 입력해주세요.'; end if;
  insert into public.point_accounts(user_id) values(target_user_id) on conflict do nothing;
  update public.point_accounts
  set balance = balance + adjustment,
      lifetime_earned = lifetime_earned + case when adjustment > 0 then adjustment else 0 end,
      lifetime_used = lifetime_used + case when adjustment < 0 then -adjustment else 0 end,
      updated_at = now()
  where user_id = target_user_id and balance + adjustment >= 0
  returning balance into new_balance;
  if new_balance is null then raise exception '포인트 잔액이 부족합니다.'; end if;
  insert into public.point_ledger(user_id, amount, balance_after, entry_type, reason, created_by)
  values(target_user_id, adjustment, new_balance, 'admin_adjust', trim(adjustment_reason), auth.uid());
  return new_balance;
end;
$$;
revoke all on function public.admin_adjust_points(uuid,integer,text) from public;
grant execute on function public.admin_adjust_points(uuid,integer,text) to authenticated;

create or replace function public.apply_checkout_benefits(
  target_intent_id uuid,
  requested_points integer default 0,
  requested_coupon_code text default null
)
returns table(payable_amount integer, applied_points integer, applied_coupon_discount integer)
language plpgsql security definer set search_path = '' as $$
declare
  intent public.payment_intents%rowtype;
  account public.point_accounts%rowtype;
  selected_coupon public.coupons%rowtype;
  held_points integer := 0;
  available_points integer := 0;
  coupon_amount integer := 0;
  minimum_external integer := 100;
  prior_uses integer := 0;
begin
  select * into intent from public.payment_intents where id=target_intent_id for update;
  if intent.id is null or intent.customer_id<>auth.uid() or intent.status<>'prepared' then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  minimum_external := coalesce((select (setting_value->>'minimum_external_amount')::integer from public.platform_settings where setting_key='payment'),100);

  if nullif(upper(trim(requested_coupon_code)),'') is not null then
    select * into selected_coupon from public.coupons c
    where upper(c.code)=upper(trim(requested_coupon_code)) and c.is_active
      and now() between c.starts_at and c.ends_at
      and c.minimum_order_amount <= intent.original_amount
      and c.applies_to in ('all',intent.kind)
      and (c.business_id is null or c.business_id=(intent.draft->>'business_id')::uuid)
    for update;
    if selected_coupon.id is null then raise exception '사용할 수 없는 할인코드입니다.'; end if;
    select count(*) into prior_uses from public.coupon_redemptions r
    where r.coupon_id=selected_coupon.id and r.user_id=intent.customer_id and r.status in ('reserved','used');
    if prior_uses>=selected_coupon.per_user_limit then raise exception '할인코드 사용 가능 횟수를 초과했습니다.'; end if;
    if selected_coupon.total_usage_limit is not null and (
      select count(*) from public.coupon_redemptions r where r.coupon_id=selected_coupon.id and r.status in ('reserved','used')
    )>=selected_coupon.total_usage_limit then raise exception '할인코드가 모두 소진되었습니다.'; end if;
    coupon_amount := case when selected_coupon.discount_type='fixed'
      then selected_coupon.discount_value::integer
      else floor(intent.original_amount * selected_coupon.discount_value / 100)::integer end;
    coupon_amount := least(coupon_amount, coalesce(selected_coupon.maximum_discount,coupon_amount), greatest(intent.original_amount-minimum_external,0));
    if coupon_amount<=0 then raise exception '이 주문에 적용할 할인금액이 없습니다.'; end if;
    insert into public.coupon_redemptions(coupon_id,user_id,payment_intent_id,discount_amount)
    values(selected_coupon.id,intent.customer_id,intent.id,coupon_amount);
  end if;

  insert into public.point_accounts(user_id) values(intent.customer_id) on conflict do nothing;
  select * into account from public.point_accounts where user_id=intent.customer_id for update;
  select greatest(account.balance-coalesce(sum(h.amount),0),0) into available_points
  from public.point_holds h where h.user_id=intent.customer_id and h.status='held' and h.expires_at>now();
  held_points := least(greatest(coalesce(requested_points,0),0), available_points, greatest(intent.original_amount-coupon_amount-minimum_external,0));
  if held_points>0 then
    insert into public.point_holds(payment_intent_id,user_id,amount,expires_at)
    values(intent.id,intent.customer_id,held_points,intent.expires_at);
  end if;

  update public.payment_intents set
    amount=original_amount-coupon_amount-held_points,
    customer_paid_amount=original_amount-coupon_amount-held_points,
    points_used=held_points,
    coupon_discount=coupon_amount,
    platform_discount=coupon_amount+held_points,
    provider='toss'
  where id=intent.id;

  return query select intent.original_amount-coupon_amount-held_points, held_points, coupon_amount;
end;
$$;
revoke all on function public.apply_checkout_benefits(uuid,integer,text) from public;

alter table public.stay_availability_blocks drop constraint if exists stay_availability_blocks_source_check;
alter table public.stay_availability_blocks add constraint stay_availability_blocks_source_check
check (source in ('manual','motf','checkout_hold','pending_payment','external_ical','external_api'));

create or replace function public.release_expired_checkout_intents()
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer;
begin
  update public.payment_intents set status='expired'
  where status in ('prepared','ready','in_progress') and expires_at<=now();
  get diagnostics affected=row_count;
  update public.point_holds h set status='released',released_at=now()
  from public.payment_intents pi where h.payment_intent_id=pi.id and h.status='held' and pi.status in ('expired','failed','cancelled','aborted');
  update public.coupon_redemptions r set status='released'
  from public.payment_intents pi where r.payment_intent_id=pi.id and r.status='reserved' and pi.status in ('expired','failed','cancelled','aborted');
  update public.market_inventory_holds h set status='released'
  from public.payment_intents pi where h.payment_intent_id=pi.id and h.status='held' and pi.status in ('expired','failed','cancelled','aborted');
  update public.stay_availability_blocks b set status='cancelled',note=coalesce(b.note,'')||' / checkout expired'
  from public.payment_intents pi where b.payment_intent_id=pi.id and b.source='checkout_hold' and b.status='active' and pi.status in ('expired','failed','cancelled','aborted');
  return affected;
end;
$$;
revoke all on function public.release_expired_checkout_intents() from public;
grant execute on function public.release_expired_checkout_intents() to anon, authenticated, service_role;

create or replace function public.stay_range_is_available(
  target_offering_id uuid,
  target_check_in date,
  target_check_out date
)
returns boolean language sql stable security definer set search_path = '' as $$
  select target_check_in<target_check_out and not exists(
    select 1 from public.stay_availability_blocks b
    where b.offering_id=target_offering_id and b.status='active'
      and b.start_date<target_check_out and b.end_date>target_check_in
      and (
        b.source not in ('pending_payment','checkout_hold')
        or exists(select 1 from public.payment_intents pi where pi.id=b.payment_intent_id and (
          (b.source='pending_payment' and pi.status in ('virtual_account_issued','waiting_for_deposit') and pi.expires_at>now())
          or (b.source='checkout_hold' and pi.status in ('prepared','ready','in_progress') and pi.expires_at>now())
        ))
      )
  );
$$;

create or replace function public.prepare_stay_checkout(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null,
  check_in_date date default null,
  check_out_date date default null,
  requested_points integer default 0,
  coupon_code text default null
)
returns table(order_id text, amount integer, original_amount integer, points_used integer, coupon_discount integer, order_name text, kind text)
language plpgsql security definer set search_path = '' as $$
declare
  room public.offerings%rowtype; business public.businesses%rowtype; intent_id uuid;
  new_order_id text; actual_in date:=coalesce(check_in_date,event_date); actual_out date:=coalesce(check_out_date,event_date+1);
  gross integer; included_people integer; benefit record;
begin
  perform public.release_expired_checkout_intents();
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists(select 1 from public.profiles where id=auth.uid() and role='user' and status='approved') then raise exception '현재 계정으로 예약할 수 없습니다.'; end if;
  if nullif(trim(customer_name),'') is null or guest_count is null or guest_count<=0 then raise exception '예약자와 인원을 확인해주세요.'; end if;
  if actual_in<current_date or actual_in>=actual_out then raise exception '숙박 일정을 다시 확인해주세요.'; end if;
  select * into room from public.offerings where id=target_offering_id and business_id=target_business_id and is_active for update;
  select * into business from public.businesses where id=target_business_id and business_type='stay' and approval_status='approved';
  if room.id is null or business.id is null then raise exception '예약 가능한 객실을 찾지 못했습니다.'; end if;
  if room.max_people is not null and guest_count>room.max_people then raise exception '객실 최대 인원을 초과했습니다.'; end if;
  if not public.stay_range_is_available(room.id,actual_in,actual_out) then raise exception '선택한 날짜에 이미 예약된 객실입니다.'; end if;
  gross:=public.calculate_stay_base_amount(room.id,actual_in,actual_out);
  included_people:=greatest(1,coalesce(room.base_people,room.min_people,room.max_people,guest_count));
  loop
    new_order_id:='TS-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    exit when not exists(select 1 from public.payment_intents where payment_intents.order_id=new_order_id);
  end loop;
  insert into public.payment_intents(order_id,customer_id,kind,amount,original_amount,customer_paid_amount,order_name,draft,provider,expires_at)
  values(new_order_id,auth.uid(),'stay',gross,gross,gross,left(business.business_name||' '||room.name,100),jsonb_build_object(
    'business_id',business.id,'offering_id',room.id,'offering_name',room.name,'customer_name',trim(customer_name),
    'group_name',nullif(trim(group_name),''),'contact_phone',nullif(trim(contact_phone),''),'event_date',actual_in,
    'check_in_date',actual_in,'check_out_date',actual_out,'guest_count',guest_count,'base_people',included_people,
    'extra_people',greatest(0,guest_count-included_people),'extras_payment_rule','onsite_direct','request_memo',nullif(trim(request_memo),'')
  ),'toss',now()+interval '15 minutes') returning id into intent_id;
  insert into public.stay_availability_blocks(business_id,offering_id,start_date,end_date,source,payment_intent_id,payment_order_id,note,created_by)
  values(business.id,room.id,actual_in,actual_out,'checkout_hold',intent_id,new_order_id,'토스 결제 진행 중',auth.uid());
  select * into benefit from public.apply_checkout_benefits(intent_id,requested_points,coupon_code);
  return query select new_order_id,benefit.payable_amount,gross,benefit.applied_points,benefit.applied_coupon_discount,left(business.business_name||' '||room.name,100),'stay'::text;
end;
$$;

create or replace function public.prepare_market_checkout(
  target_business_id uuid,
  customer_name text,
  contact_phone text,
  pickup_place text,
  pickup_time time,
  request_memo text,
  items jsonb,
  requested_points integer default 0,
  coupon_code text default null
)
returns table(order_id text, amount integer, original_amount integer, points_used integer, coupon_discount integer, order_name text, kind text)
language plpgsql security definer set search_path = '' as $$
declare
  business public.businesses%rowtype; intent_id uuid; snapshot_items jsonb; gross bigint; item_count integer; first_name text; new_order_id text; new_name text; benefit record;
begin
  perform public.release_expired_checkout_intents();
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if nullif(trim(customer_name),'') is null or nullif(trim(pickup_place),'') is null then raise exception '주문자와 수령 정보를 입력해주세요.'; end if;
  if jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then raise exception '주문 상품이 없습니다.'; end if;
  select * into business from public.businesses where id=target_business_id and business_type='market' and approval_status='approved';
  if business.id is null then raise exception '주문 가능한 공판장을 찾지 못했습니다.'; end if;
  if exists(select 1 from jsonb_to_recordset(items) x(offering_id uuid,quantity integer)
    left join public.offerings o on o.id=x.offering_id and o.business_id=target_business_id and o.is_active
    where x.offering_id is null or x.quantity is null or x.quantity<=0 or x.quantity>1000 or o.id is null) then raise exception '판매 상품과 수량을 확인해주세요.'; end if;
  if exists(select 1 from jsonb_to_recordset(items) x(offering_id uuid,quantity integer)
    join public.offerings o on o.id=x.offering_id where o.is_alcohol) and not public.current_user_is_adult() then
    raise exception '주류는 휴대폰 본인확인으로 성인 인증된 회원만 주문할 수 있습니다.';
  end if;
  if exists(select 1 from jsonb_to_recordset(items) x(offering_id uuid,quantity integer)
    join public.offerings o on o.id=x.offering_id
    where o.stock_quantity is not null and o.stock_quantity-coalesce((select sum(h.quantity) from public.market_inventory_holds h where h.offering_id=o.id and h.status='held' and h.expires_at>now()),0)<x.quantity) then raise exception '재고가 부족한 상품이 있습니다.'; end if;
  select jsonb_agg(jsonb_build_object('offering_id',g.offering_id,'item_name',g.item_name,'quantity',g.quantity,'unit_price',g.unit_price,'is_alcohol',g.is_alcohol) order by g.item_name),
    sum(g.unit_price::bigint*g.quantity),count(*),min(g.item_name)
  into snapshot_items,gross,item_count,first_name from(
    select o.id offering_id,o.name item_name,sum(x.quantity)::integer quantity,o.price unit_price,o.is_alcohol
    from jsonb_to_recordset(items) x(offering_id uuid,quantity integer) join public.offerings o on o.id=x.offering_id
    group by o.id,o.name,o.price,o.is_alcohol
  ) g;
  if gross is null or gross<=0 or gross>2147483647 then raise exception '주문 금액을 확인해주세요.'; end if;
  new_name:=left(business.business_name||' '||first_name||case when item_count>1 then ' 외 '||(item_count-1)||'개' else '' end,100);
  loop
    new_order_id:='TM-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    exit when not exists(select 1 from public.payment_intents where payment_intents.order_id=new_order_id);
  end loop;
  insert into public.payment_intents(order_id,customer_id,kind,amount,original_amount,customer_paid_amount,order_name,draft,provider,expires_at)
  values(new_order_id,auth.uid(),'market',gross::integer,gross::integer,gross::integer,new_name,jsonb_build_object(
    'business_id',business.id,'customer_name',trim(customer_name),'contact_phone',nullif(trim(contact_phone),''),
    'pickup_place',trim(pickup_place),'pickup_time',pickup_time,'request_memo',nullif(trim(request_memo),''),'items',snapshot_items
  ),'toss',now()+interval '15 minutes') returning id into intent_id;
  insert into public.market_inventory_holds(payment_intent_id,offering_id,quantity,expires_at)
  select intent_id,(x->>'offering_id')::uuid,(x->>'quantity')::integer,now()+interval '15 minutes' from jsonb_array_elements(snapshot_items)x;
  select * into benefit from public.apply_checkout_benefits(intent_id,requested_points,coupon_code);
  return query select new_order_id,benefit.payable_amount,gross::integer,benefit.applied_points,benefit.applied_coupon_discount,new_name,'market'::text;
end;
$$;

revoke all on function public.prepare_stay_checkout(uuid,uuid,text,text,text,date,integer,text,date,date,integer,text) from public;
revoke all on function public.prepare_market_checkout(uuid,text,text,text,time,text,jsonb,integer,text) from public;
grant execute on function public.prepare_stay_checkout(uuid,uuid,text,text,text,date,integer,text,date,date,integer,text) to authenticated;
grant execute on function public.prepare_market_checkout(uuid,text,text,text,time,text,jsonb,integer,text) to authenticated;

create or replace function public.finalize_toss_payment_intent(
  target_customer_id uuid,
  target_order_id text,
  target_payment_key text,
  toss_payment jsonb
)
returns table(transaction_id uuid, kind text)
language plpgsql security definer set search_path = '' as $$
declare
  intent public.payment_intents%rowtype; new_id uuid; current_balance integer; response_status text; response_amount integer;
begin
  select * into intent from public.payment_intents where order_id=target_order_id for update;
  if intent.id is null or intent.customer_id<>target_customer_id then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  if intent.status='confirmed' then return query select intent.transaction_id,intent.kind; return; end if;
  response_status:=toss_payment->>'status'; response_amount:=coalesce((toss_payment->>'totalAmount')::integer,-1);
  if toss_payment->>'orderId' is distinct from intent.order_id or toss_payment->>'paymentKey' is distinct from target_payment_key
     or response_amount<>intent.amount or response_status<>'DONE' then raise exception '토스 승인 정보와 결제 원장이 일치하지 않습니다.'; end if;

  if intent.kind='stay' then
    if not exists(select 1 from public.stay_availability_blocks where payment_intent_id=intent.id and source='checkout_hold' and status='active') then
      raise exception '객실 결제 보관 시간이 만료되었습니다. 다시 예약해주세요.';
    end if;
    insert into public.reservations(business_id,customer_id,offering_id,customer_name,group_name,contact_phone,event_date,end_date,guest_count,offering_name,total_amount,base_accommodation_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method,pricing_breakdown,request_memo)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,(intent.draft->>'offering_id')::uuid,intent.draft->>'customer_name',intent.draft->>'group_name',intent.draft->>'contact_phone',(intent.draft->>'check_in_date')::date,(intent.draft->>'check_out_date')::date,(intent.draft->>'guest_count')::integer,intent.draft->>'offering_name',intent.original_amount,intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,toss_payment->>'method',jsonb_build_array(jsonb_build_object('label','객실 기본금','amount',intent.original_amount)),intent.draft->>'request_memo') returning id into new_id;
    update public.stay_availability_blocks set source='motf',reservation_id=new_id,note='토스 결제 승인 완료' where payment_intent_id=intent.id and status='active';
  elsif intent.kind='market' then
    insert into public.market_orders(business_id,customer_id,customer_name,contact_phone,pickup_place,pickup_time,request_memo,total_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,intent.draft->>'customer_name',intent.draft->>'contact_phone',intent.draft->>'pickup_place',(intent.draft->>'pickup_time')::time,intent.draft->>'request_memo',intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,toss_payment->>'method') returning id into new_id;
    insert into public.market_order_items(order_id,offering_id,item_name,quantity,unit_price)
    select new_id,x.offering_id,x.item_name,x.quantity,x.unit_price from jsonb_to_recordset(intent.draft->'items') x(offering_id uuid,item_name text,quantity integer,unit_price integer,is_alcohol boolean);
    update public.offerings o set stock_quantity=o.stock_quantity-h.quantity,updated_at=now()
    from public.market_inventory_holds h where h.payment_intent_id=intent.id and h.offering_id=o.id and h.status='held' and o.stock_quantity is not null;
    update public.market_inventory_holds set status='consumed' where payment_intent_id=intent.id and status='held';
  else
    raise exception '신규 결제에서 지원하지 않는 거래 종류입니다.';
  end if;

  if intent.points_used>0 then
    update public.point_accounts set balance=balance-intent.points_used,lifetime_used=lifetime_used+intent.points_used,updated_at=now()
    where user_id=intent.customer_id and balance>=intent.points_used returning balance into current_balance;
    if current_balance is null then raise exception '포인트 잔액이 변경되어 결제를 확정할 수 없습니다.'; end if;
    insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id)
    values(intent.customer_id,-intent.points_used,current_balance,'use','결제 포인트 사용',intent.kind,new_id);
    update public.point_holds set status='consumed',consumed_at=now() where payment_intent_id=intent.id;
  end if;
  update public.coupon_redemptions set status='used',used_at=now() where payment_intent_id=intent.id and status='reserved';
  update public.payment_intents set status='confirmed',provider='toss',provider_status=response_status,payment_key=target_payment_key,provider_payment_id=target_payment_key,payment_method=toss_payment->>'method',payment_response=toss_payment,transaction_id=new_id,paid_at=now(),confirmed_at=now() where id=intent.id;
  return query select new_id,intent.kind;
end;
$$;
revoke all on function public.finalize_toss_payment_intent(uuid,text,text,jsonb) from public;
grant execute on function public.finalize_toss_payment_intent(uuid,text,text,jsonb) to service_role;

-- New extra-charge payment creation is disabled. Historical rows stay available for audits.
revoke execute on function public.create_reservation_extra_charge_request(uuid,jsonb,text,timestamptz) from authenticated;
revoke execute on function public.prepare_extra_charge_payment(uuid) from authenticated;
comment on table public.reservation_extra_charge_requests is 'Legacy online extra-charge records. New stay extras are paid directly onsite.';

alter table public.partner_settlements
  add column if not exists customer_paid_amount integer,
  add column if not exists platform_discount_amount integer not null default 0,
  add column if not exists payment_processing_fee integer not null default 0;

create or replace function public.sync_partner_settlements()
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer:=0; changed integer; stay_rate numeric; market_rate numeric;
begin
  stay_rate:=coalesce((select (setting_value->>'stay_rate')::numeric from public.platform_settings where setting_key='commission'),0.035);
  market_rate:=coalesce((select (setting_value->>'market_rate')::numeric from public.platform_settings where setting_key='commission'),0.035);
  insert into public.partner_settlements(business_id,transaction_kind,transaction_id,gross_amount,customer_paid_amount,platform_discount_amount,commission_rate,commission_amount,payout_amount)
  select r.business_id,'stay',r.id,coalesce(r.original_amount,r.base_accommodation_amount,r.total_amount),coalesce(r.customer_paid_amount,r.total_amount),coalesce(r.points_used,0)+coalesce(r.coupon_discount,0),coalesce(b.commission_rate_override,stay_rate),floor(coalesce(r.original_amount,r.base_accommodation_amount,r.total_amount)*coalesce(b.commission_rate_override,stay_rate))::integer,coalesce(r.original_amount,r.base_accommodation_amount,r.total_amount)-floor(coalesce(r.original_amount,r.base_accommodation_amount,r.total_amount)*coalesce(b.commission_rate_override,stay_rate))::integer
  from public.reservations r join public.businesses b on b.id=r.business_id where r.status in ('confirmed','completed')
  on conflict(transaction_kind,transaction_id) do update set business_id=excluded.business_id,gross_amount=excluded.gross_amount,customer_paid_amount=excluded.customer_paid_amount,platform_discount_amount=excluded.platform_discount_amount,commission_rate=excluded.commission_rate,commission_amount=excluded.commission_amount,payout_amount=excluded.payout_amount,status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics changed=row_count; affected:=affected+changed;
  insert into public.partner_settlements(business_id,transaction_kind,transaction_id,gross_amount,customer_paid_amount,platform_discount_amount,commission_rate,commission_amount,payout_amount)
  select o.business_id,'market',o.id,coalesce(o.original_amount,o.total_amount),coalesce(o.customer_paid_amount,o.total_amount),coalesce(o.points_used,0)+coalesce(o.coupon_discount,0),coalesce(b.commission_rate_override,market_rate),floor(coalesce(o.original_amount,o.total_amount)*coalesce(b.commission_rate_override,market_rate))::integer,coalesce(o.original_amount,o.total_amount)-floor(coalesce(o.original_amount,o.total_amount)*coalesce(b.commission_rate_override,market_rate))::integer
  from public.market_orders o join public.businesses b on b.id=o.business_id where o.status in ('confirmed','completed')
  on conflict(transaction_kind,transaction_id) do update set business_id=excluded.business_id,gross_amount=excluded.gross_amount,customer_paid_amount=excluded.customer_paid_amount,platform_discount_amount=excluded.platform_discount_amount,commission_rate=excluded.commission_rate,commission_amount=excluded.commission_amount,payout_amount=excluded.payout_amount,status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics changed=row_count; affected:=affected+changed;
  update public.partner_settlements s set status='cancelled' where s.status='pending' and ((s.transaction_kind='stay' and not exists(select 1 from public.reservations r where r.id=s.transaction_id and r.status in ('confirmed','completed'))) or (s.transaction_kind='market' and not exists(select 1 from public.market_orders o where o.id=s.transaction_id and o.status in ('confirmed','completed'))) or s.transaction_kind='extra_charge');
  return affected;
end;
$$;

comment on column public.partner_settlements.platform_discount_amount is 'Points/coupons funded by moTF; partner payout remains based on gross seller price';
comment on column public.payment_intents.original_amount is 'Seller gross price before moTF points and coupon funding';
comment on column public.payment_intents.amount is 'Amount approved by the external payment provider';
