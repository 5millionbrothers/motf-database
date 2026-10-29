-- Additive preparation only: does not switch checkout or rewrite historical providers.
begin;

create table if not exists public.payment_provider_operations (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('toss','nicepay')),
  operation_key text not null check (length(operation_key) between 1 and 120),
  operation_kind text not null check (operation_kind in ('approve','net_cancel','refund','payout','payout_cancel')),
  payment_intent_id uuid references public.payment_intents(id) on delete restrict,
  settlement_id uuid references public.partner_settlements(id) on delete restrict,
  merchant_id text not null check (length(merchant_id) between 1 and 50),
  amount bigint not null check (amount > 0 and amount < 1000000000000),
  payload_fingerprint text not null check (payload_fingerprint ~ '^[a-f0-9]{64}$'),
  state text not null default 'submitting' check (state in ('submitting','unknown','requested','processing','succeeded','failed','cancelled')),
  provider_reference text,
  provider_result_code text,
  context jsonb not null default '{}'::jsonb,
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider,operation_key),
  check ((operation_kind in ('approve','net_cancel','refund') and payment_intent_id is not null and settlement_id is null)
    or (operation_kind in ('payout','payout_cancel') and settlement_id is not null and payment_intent_id is null))
);

-- Different request keys must not bypass protection for the same financial action.
alter table public.payment_provider_operations add column if not exists context jsonb not null default '{}'::jsonb;
create unique index if not exists payment_provider_active_approval
  on public.payment_provider_operations(payment_intent_id)
  where operation_kind='approve' and state not in ('failed','cancelled');
create unique index if not exists payment_provider_active_refund
  on public.payment_provider_operations(payment_intent_id)
  where operation_kind='refund' and state in ('submitting','unknown','requested','processing');
create unique index if not exists payment_provider_active_payout
  on public.payment_provider_operations(settlement_id)
  where operation_kind='payout' and state not in ('failed','cancelled');

alter table public.payment_provider_operations enable row level security;
revoke all on public.payment_provider_operations from public, anon, authenticated;
grant select, insert, update on public.payment_provider_operations to service_role;

create table if not exists public.nicepay_settlement_links (
  settlement_id uuid primary key references public.partner_settlements(id) on delete restrict,
  merchant_id text not null check (merchant_id ~ '^[A-Za-z0-9]{10}$'),
  sub_id text not null check (sub_id ~ '^[A-Za-z0-9]{1,50}$'),
  payout_date date not null,
  provider_seq text check (provider_seq ~ '^[0-9]{1,20}$'),
  operation_id uuid unique references public.payment_provider_operations(id) on delete restrict,
  account_fingerprint text not null check (account_fingerprint ~ '^[a-f0-9]{64}$'),
  -- Actual destination uses the sub-mall's account at transfer time, not request time.
  account_change_hold boolean not null default false,
  state text not null default 'draft' check (state in ('draft','submitting','unknown','requested','processing','succeeded','failed','cancelled')),
  reconciled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(merchant_id,provider_seq)
);
alter table public.nicepay_settlement_links enable row level security;
revoke all on public.nicepay_settlement_links from public, anon, authenticated;
grant select, insert, update on public.nicepay_settlement_links to service_role;

create or replace function public.claim_payment_provider_operation(
  target_provider text, target_operation_key text, target_operation_kind text,
  target_merchant_id text, target_amount bigint, target_fingerprint text,
  target_payment_intent_id uuid default null, target_settlement_id uuid default null
)
returns table(operation_id uuid, claimed boolean, operation_state text)
language plpgsql security definer set search_path='' as $$
declare row_data public.payment_provider_operations%rowtype; inserted_id uuid;
begin
  -- Unknown outcomes are intentionally never retried automatically.
  insert into public.payment_provider_operations(provider,operation_key,operation_kind,merchant_id,amount,
    payload_fingerprint,payment_intent_id,settlement_id)
  values(target_provider,target_operation_key,target_operation_kind,target_merchant_id,target_amount,
    target_fingerprint,target_payment_intent_id,target_settlement_id)
  on conflict(provider,operation_key) do nothing returning id into inserted_id;
  select * into row_data from public.payment_provider_operations
    where provider=target_provider and operation_key=target_operation_key for update;
  if row_data.payload_fingerprint is distinct from target_fingerprint or row_data.amount is distinct from target_amount
    or row_data.merchant_id is distinct from target_merchant_id or row_data.operation_kind is distinct from target_operation_kind
    or row_data.payment_intent_id is distinct from target_payment_intent_id or row_data.settlement_id is distinct from target_settlement_id then
    raise exception '동일 처리키에 다른 결제·환불·지급 요청을 사용할 수 없습니다.';
  end if;
  return query select row_data.id,inserted_id is not null,row_data.state;
end;
$$;
revoke all on function public.claim_payment_provider_operation(text,text,text,text,bigint,text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.claim_payment_provider_operation(text,text,text,text,bigint,text,uuid,uuid) to service_role;

comment on table public.payment_provider_operations is 'Server-only idempotency/reconciliation ledger. Never store keys, AuthToken, raw request, account numbers or full PG responses here.';
comment on table public.nicepay_settlement_links is 'NICE payout tracking, separate from pending/paid business settlements. API acceptance is not payment success.';

commit;
