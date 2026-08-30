-- Audit log for high-risk operator payment and reservation recovery actions.

create table if not exists public.admin_transaction_actions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references public.profiles(id) on delete set null,
  action_type text not null check (action_type in ('reject','cancel','reconcile_payment','manual_block','release_block')),
  transaction_kind text check (transaction_kind is null or transaction_kind in ('stay','market')),
  transaction_id uuid,
  order_id text,
  reason text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_transaction_actions_created_idx
on public.admin_transaction_actions(created_at desc);

create index if not exists admin_transaction_actions_transaction_idx
on public.admin_transaction_actions(transaction_kind, transaction_id, created_at desc);

alter table public.admin_transaction_actions enable row level security;

drop policy if exists "admin_transaction_actions_admin_read" on public.admin_transaction_actions;
create policy "admin_transaction_actions_admin_read"
on public.admin_transaction_actions for select to authenticated
using (public.is_admin());

grant select on public.admin_transaction_actions to authenticated;
grant select, insert on public.admin_transaction_actions to service_role;

comment on table public.admin_transaction_actions is
'Immutable audit trail for operator-triggered payment refunds, cancellations and reconciliation.';
