-- Partner operations dashboard, settlement account storage and internal test users.

alter table public.profiles
  add column if not exists is_test_account boolean not null default false;

comment on column public.profiles.is_test_account is
  'Internal moTF QA account. These accounts are created only by the protected admin API.';

create index if not exists profiles_test_account_idx
on public.profiles(is_test_account)
where is_test_account = true;

create table if not exists public.business_settlement_accounts (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists business_settlement_accounts_set_updated_at
on public.business_settlement_accounts;
create trigger business_settlement_accounts_set_updated_at
before update on public.business_settlement_accounts
for each row execute procedure public.set_updated_at();

alter table public.business_settlement_accounts enable row level security;

drop policy if exists "business_settlement_accounts_participant_read"
on public.business_settlement_accounts;
create policy "business_settlement_accounts_participant_read"
on public.business_settlement_accounts
for select to authenticated
using (public.owns_business(business_id) or public.is_admin());

drop policy if exists "business_settlement_accounts_owner_insert"
on public.business_settlement_accounts;
create policy "business_settlement_accounts_owner_insert"
on public.business_settlement_accounts
for insert to authenticated
with check (public.owns_business(business_id) or public.is_admin());

drop policy if exists "business_settlement_accounts_owner_update"
on public.business_settlement_accounts;
create policy "business_settlement_accounts_owner_update"
on public.business_settlement_accounts
for update to authenticated
using (public.owns_business(business_id) or public.is_admin())
with check (public.owns_business(business_id) or public.is_admin());

grant select, insert, update on public.business_settlement_accounts to authenticated;

comment on table public.business_settlement_accounts is
  'Private payout account data visible only to the owning partner and approved admins';

grant select, insert, update on public.profiles to service_role;
grant select, insert, update on public.point_accounts to service_role;

drop function if exists public.list_own_partner_settlements();
create function public.list_own_partner_settlements()
returns table(
  id uuid,
  business_id uuid,
  business_name text,
  transaction_kind text,
  transaction_id uuid,
  customer_name text,
  target_name text,
  transaction_date date,
  gross_amount integer,
  customer_paid_amount integer,
  platform_discount_amount integer,
  commission_rate numeric,
  commission_amount integer,
  payout_amount integer,
  status text,
  paid_at timestamptz,
  note text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.status = 'approved'
      and p.role in ('partner', 'admin')
  ) then
    raise exception '사장님 또는 운영자 권한이 필요합니다.';
  end if;

  perform public.sync_partner_settlements();

  return query
  select
    s.id,
    s.business_id,
    b.business_name,
    s.transaction_kind,
    s.transaction_id,
    coalesce(r.customer_name, o.customer_name, '이용자') as customer_name,
    coalesce(
      r.offering_name,
      (
        select string_agg(moi.item_name || ' ' || moi.quantity || '개', ', ' order by moi.item_name)
        from public.market_order_items moi
        where moi.order_id = o.id
      ),
      '거래'
    ) as target_name,
    coalesce(r.event_date, o.created_at::date, s.created_at::date) as transaction_date,
    s.gross_amount,
    coalesce(s.customer_paid_amount, s.gross_amount) as customer_paid_amount,
    coalesce(s.platform_discount_amount, 0) as platform_discount_amount,
    s.commission_rate,
    s.commission_amount,
    s.payout_amount,
    s.status,
    s.paid_at,
    s.note,
    s.created_at
  from public.partner_settlements s
  join public.businesses b on b.id = s.business_id
  left join public.reservations r
    on s.transaction_kind = 'stay' and r.id = s.transaction_id
  left join public.market_orders o
    on s.transaction_kind = 'market' and o.id = s.transaction_id
  where s.status <> 'cancelled'
    and (b.owner_id = auth.uid() or public.is_admin())
  order by s.created_at desc;
end;
$$;

revoke all on function public.list_own_partner_settlements() from public;
grant execute on function public.list_own_partner_settlements() to authenticated;
