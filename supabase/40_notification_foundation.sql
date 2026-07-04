-- moTF notification foundation.
-- Stores Kakao Alimtalk template metadata, queued notifications, and delivery logs.
-- The first implementation can run in mock mode before a Kakao official dealer is selected.

create table if not exists public.notification_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique,
  channel text not null default 'kakao_alimtalk'
    check (channel in ('kakao_alimtalk', 'sms', 'email', 'internal')),
  audience text not null
    check (audience in ('user', 'owner', 'admin', 'system')),
  provider text not null default 'mock',
  provider_template_code text,
  title text not null,
  body text not null,
  buttons jsonb not null default '[]'::jsonb,
  status text not null default 'draft'
    check (status in ('draft', 'submitted', 'approved', 'rejected', 'paused')),
  memo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  event_key text not null,
  template_key text not null references public.notification_templates(template_key),
  recipient_user_id uuid references public.profiles(id) on delete set null,
  recipient_role text not null
    check (recipient_role in ('user', 'owner', 'admin', 'system')),
  recipient_name text,
  recipient_phone text,
  payload jsonb not null default '{}'::jsonb,
  button_links jsonb not null default '{}'::jsonb,
  dedupe_key text unique,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'mock_sent', 'sent', 'failed', 'skipped', 'cancelled')),
  provider text not null default 'mock',
  provider_message_id text,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  failed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notification_logs (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid references public.notification_outbox(id) on delete set null,
  template_key text,
  recipient_role text,
  recipient_phone text,
  action text not null default 'dispatch',
  status text not null,
  provider text not null default 'mock',
  provider_message_id text,
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb not null default '{}'::jsonb,
  error_message text,
  created_at timestamptz not null default now()
);

create index if not exists notification_templates_status_idx
on public.notification_templates(status, audience);

create index if not exists notification_outbox_status_next_idx
on public.notification_outbox(status, next_attempt_at, created_at);

create index if not exists notification_outbox_recipient_idx
on public.notification_outbox(recipient_user_id, created_at desc);

create index if not exists notification_logs_outbox_idx
on public.notification_logs(outbox_id, created_at desc);

drop trigger if exists notification_templates_set_updated_at on public.notification_templates;
create trigger notification_templates_set_updated_at
before update on public.notification_templates
for each row execute procedure public.set_updated_at();

drop trigger if exists notification_outbox_set_updated_at on public.notification_outbox;
create trigger notification_outbox_set_updated_at
before update on public.notification_outbox
for each row execute procedure public.set_updated_at();

alter table public.notification_templates enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.notification_logs enable row level security;

drop policy if exists "notification_templates_admin_select" on public.notification_templates;
create policy "notification_templates_admin_select"
on public.notification_templates for select to authenticated
using (public.is_admin());

drop policy if exists "notification_outbox_admin_select" on public.notification_outbox;
create policy "notification_outbox_admin_select"
on public.notification_outbox for select to authenticated
using (public.is_admin());

drop policy if exists "notification_logs_admin_select" on public.notification_logs;
create policy "notification_logs_admin_select"
on public.notification_logs for select to authenticated
using (public.is_admin());

grant select on public.notification_templates, public.notification_outbox, public.notification_logs to authenticated;

insert into public.notification_templates (template_key, audience, title, body, buttons, memo)
values
  ('USER_VA_ISSUED_V1', 'user', '가상계좌 발급 안내', '가상계좌가 발급되었습니다.', '[{"name":"예약/주문내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_DEPOSIT_DEADLINE_V1', 'user', '입금 기한 안내', '입금 기한이 가까워지고 있습니다.', '[{"name":"예약/주문내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_RESERVATION_REQUESTED_V1', 'user', '입금 확인 및 예약 요청 접수', '입금이 확인되어 예약 요청이 접수되었습니다.', '[{"name":"예약내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_RESERVATION_CONFIRMED_V1', 'user', '예약 확정', '예약이 확정되었습니다.', '[{"name":"예약내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_RESERVATION_CANCELLED_V1', 'user', '예약 취소 및 환불 안내', '예약 요청이 취소 처리되었습니다.', '[{"name":"예약내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_ORDER_RECEIVED_V1', 'user', '주문 요청 접수', '주문 요청이 접수되었습니다.', '[{"name":"주문내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_ORDER_STATUS_V1', 'user', '주문 상태 변경', '주문 상태가 변경되었습니다.', '[{"name":"주문내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_CHAT_RECEIVED_V1', 'user', '새 채팅 도착', '새 채팅이 도착했습니다.', '[{"name":"채팅 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_SUPPORT_REPLY_V1', 'user', '문의 답변 등록', '문의 답변이 등록되었습니다.', '[{"name":"마이페이지 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('USER_REFUND_STATUS_V1', 'user', '환불 상태 변경', '환불 상태가 변경되었습니다.', '[{"name":"예약내역 보기","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_RESERVATION_REQUEST_V1', 'owner', '새 예약 요청', '새 예약 요청이 접수되었습니다.', '[{"name":"예약 확인","type":"WL"},{"name":"수락 처리","type":"WL"},{"name":"취소 처리","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_ORDER_REQUEST_V1', 'owner', '새 주문 요청', '새 주문 요청이 접수되었습니다.', '[{"name":"주문 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_CHAT_RECEIVED_V1', 'owner', '이용자 채팅 도착', '새 채팅이 도착했습니다.', '[{"name":"채팅 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_ADMIN_NOTICE_V1', 'owner', '운영자 안내 도착', '운영자 안내가 도착했습니다.', '[{"name":"채팅 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_CANCEL_REFUND_REQUEST_V1', 'owner', '예약 취소/환불 확인', '예약 취소 또는 환불 확인이 필요합니다.', '[{"name":"예약 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_SETTLEMENT_STATUS_V1', 'owner', '정산 상태 변경', '정산 상태가 변경되었습니다.', '[{"name":"정산 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('OWNER_AVAILABILITY_CONFLICT_V1', 'owner', '객실 일정 확인', '객실 일정 확인이 필요합니다.', '[{"name":"객실 관리","type":"WL"}]'::jsonb, '초기 MVP에서는 예외 상황에만 사용'),
  ('ADMIN_RESERVATION_STATUS_V1', 'admin', '예약 상태 변경', '예약 상태가 변경되었습니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_REFUND_REQUIRED_V1', 'admin', '환불 확인 필요', '환불 확인이 필요합니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_REFUND_FAILED_V1', 'admin', '환불 처리 확인 필요', '환불 처리 확인이 필요합니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_NEW_ORDER_V1', 'admin', '새 주문 요청', '새 주문 요청이 접수되었습니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_PAYMENT_WEBHOOK_FAILED_V1', 'admin', '결제 처리 확인 필요', '결제 처리 확인이 필요합니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_SUPPORT_RECEIVED_V1', 'admin', '새 문의 접수', '새 문의가 접수되었습니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_CHAT_DELAYED_V1', 'admin', '채팅 응답 확인 필요', '채팅 응답 확인이 필요합니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_SETTLEMENT_STATUS_V1', 'admin', '정산 상태 변경', '정산 상태가 변경되었습니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_AVAILABILITY_CHANGED_V1', 'admin', '객실 상태 변경', '객실 상태가 변경되었습니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안'),
  ('ADMIN_NOTIFICATION_FAILED_V1', 'admin', '알림 발송 확인 필요', '알림 발송 확인이 필요합니다.', '[{"name":"관리자 확인","type":"WL"}]'::jsonb, '심사 전 초안')
on conflict (template_key) do update
set
  audience = excluded.audience,
  title = excluded.title,
  body = excluded.body,
  buttons = excluded.buttons,
  memo = excluded.memo,
  updated_at = now();

create or replace function public.enqueue_notification(
  target_event_key text,
  target_template_key text,
  target_recipient_role text,
  target_recipient_user_id uuid default null,
  target_recipient_name text default null,
  target_recipient_phone text default null,
  target_payload jsonb default '{}'::jsonb,
  target_button_links jsonb default '{}'::jsonb,
  target_dedupe_key text default null,
  target_next_attempt_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_id uuid;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception '로그인이 필요합니다.';
  end if;

  if target_recipient_role not in ('user', 'owner', 'admin', 'system') then
    raise exception '알림 수신 유형이 올바르지 않습니다.';
  end if;

  if not exists (
    select 1 from public.notification_templates
    where template_key = target_template_key
  ) then
    raise exception '알림 템플릿을 찾을 수 없습니다.';
  end if;

  insert into public.notification_outbox (
    event_key,
    template_key,
    recipient_user_id,
    recipient_role,
    recipient_name,
    recipient_phone,
    payload,
    button_links,
    dedupe_key,
    next_attempt_at
  ) values (
    target_event_key,
    target_template_key,
    target_recipient_user_id,
    target_recipient_role,
    nullif(target_recipient_name, ''),
    nullif(target_recipient_phone, ''),
    coalesce(target_payload, '{}'::jsonb),
    coalesce(target_button_links, '{}'::jsonb),
    nullif(target_dedupe_key, ''),
    coalesce(target_next_attempt_at, now())
  )
  on conflict (dedupe_key) do update
  set
    payload = excluded.payload,
    button_links = excluded.button_links,
    recipient_phone = coalesce(excluded.recipient_phone, public.notification_outbox.recipient_phone),
    recipient_name = coalesce(excluded.recipient_name, public.notification_outbox.recipient_name),
    status = case
      when public.notification_outbox.status in ('queued', 'failed', 'cancelled') then 'queued'
      else public.notification_outbox.status
    end,
    next_attempt_at = excluded.next_attempt_at,
    updated_at = now()
  returning id into result_id;

  return result_id;
end;
$$;

create or replace function public.claim_notification_batch(
  batch_limit integer default 20
)
returns setof public.notification_outbox
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '알림 처리 권한이 없습니다.';
  end if;

  return query
  with candidates as (
    select id
    from public.notification_outbox
    where status = 'queued'
      and next_attempt_at <= now()
      and attempt_count < max_attempts
    order by created_at asc
    limit greatest(1, least(coalesce(batch_limit, 20), 100))
    for update skip locked
  )
  update public.notification_outbox o
  set
    status = 'processing',
    locked_at = now(),
    attempt_count = attempt_count + 1,
    updated_at = now()
  from candidates c
  where o.id = c.id
  returning o.*;
end;
$$;

create or replace function public.complete_notification(
  target_outbox_id uuid,
  final_status text,
  target_provider text default 'mock',
  target_provider_message_id text default null,
  target_request_payload jsonb default '{}'::jsonb,
  target_response_payload jsonb default '{}'::jsonb,
  target_error_message text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_row public.notification_outbox%rowtype;
  normalized_status text := final_status;
  next_status text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '알림 처리 권한이 없습니다.';
  end if;

  if normalized_status not in ('mock_sent', 'sent', 'failed', 'skipped', 'cancelled') then
    raise exception '알림 처리 상태가 올바르지 않습니다.';
  end if;

  select * into current_row
  from public.notification_outbox
  where id = target_outbox_id
  for update;

  if current_row.id is null then
    raise exception '알림 대기열을 찾을 수 없습니다.';
  end if;

  next_status := normalized_status;
  if normalized_status = 'failed' and current_row.attempt_count < current_row.max_attempts then
    next_status := 'queued';
  end if;

  update public.notification_outbox
  set
    status = next_status,
    provider = coalesce(nullif(target_provider, ''), provider),
    provider_message_id = coalesce(nullif(target_provider_message_id, ''), provider_message_id),
    sent_at = case when normalized_status in ('mock_sent', 'sent') then now() else sent_at end,
    failed_at = case when normalized_status = 'failed' and next_status = 'failed' then now() else failed_at end,
    next_attempt_at = case
      when normalized_status = 'failed' and next_status = 'queued'
        then now() + (interval '5 minutes' * greatest(current_row.attempt_count, 1))
      else next_attempt_at
    end,
    locked_at = null,
    last_error = case when normalized_status = 'failed' then target_error_message else null end,
    updated_at = now()
  where id = target_outbox_id;

  insert into public.notification_logs (
    outbox_id,
    template_key,
    recipient_role,
    recipient_phone,
    status,
    provider,
    provider_message_id,
    request_payload,
    response_payload,
    error_message
  ) values (
    current_row.id,
    current_row.template_key,
    current_row.recipient_role,
    current_row.recipient_phone,
    normalized_status,
    coalesce(nullif(target_provider, ''), current_row.provider),
    nullif(target_provider_message_id, ''),
    coalesce(target_request_payload, '{}'::jsonb),
    coalesce(target_response_payload, '{}'::jsonb),
    target_error_message
  );
end;
$$;

revoke all on function public.enqueue_notification(text, text, text, uuid, text, text, jsonb, jsonb, text, timestamptz) from public;
revoke all on function public.claim_notification_batch(integer) from public;
revoke all on function public.complete_notification(uuid, text, text, text, jsonb, jsonb, text) from public;

grant execute on function public.enqueue_notification(text, text, text, uuid, text, text, jsonb, jsonb, text, timestamptz) to authenticated, service_role;
grant execute on function public.claim_notification_batch(integer) to authenticated, service_role;
grant execute on function public.complete_notification(uuid, text, text, text, jsonb, jsonb, text) to authenticated, service_role;
