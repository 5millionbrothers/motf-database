-- moTF notification full coverage.
-- Adds the remaining template hooks and maintenance RPCs for Alimtalk launch readiness.

create or replace function public.notification_support_type_ko(case_type text)
returns text
language sql
stable
set search_path = ''
as $$
  select case case_type
    when 'inquiry' then '문의'
    when 'dispute' then '분쟁'
    else coalesce(case_type, '문의')
  end;
$$;

create or replace function public.notification_refund_status_ko(status_value text)
returns text
language sql
stable
set search_path = ''
as $$
  select case status_value
    when 'none' then '환불 없음'
    when 'required' then '환불 접수'
    when 'processing' then '환불 처리중'
    when 'refunded' then '환불 완료'
    when 'failed' then '환불 확인 필요'
    else coalesce(status_value, '')
  end;
$$;

create or replace function public.notification_settlement_status_ko(status_value text)
returns text
language sql
stable
set search_path = ''
as $$
  select case status_value
    when 'pending' then '정산 대기'
    when 'paid' then '정산 완료'
    when 'cancelled' then '정산 취소'
    else coalesce(status_value, '')
  end;
$$;

create or replace function public.notification_block_source_ko(source_value text)
returns text
language sql
stable
set search_path = ''
as $$
  select case source_value
    when 'manual' then '수동 차단'
    when 'motf' then 'moTF 예약'
    when 'pending_payment' then '입금 대기'
    when 'external_ical' then '외부 캘린더'
    when 'external_api' then '외부 연동'
    else coalesce(source_value, '')
  end;
$$;

create or replace function public.enqueue_support_case_insert_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_link text;
begin
  admin_link := public.notification_owner_url('/?section=support&caseId=' || new.id::text);

  perform public.enqueue_admin_notifications(
    p_event_key := 'support_received',
    p_template_key := 'ADMIN_SUPPORT_RECEIVED_V1',
    p_payload := jsonb_build_object(
      '문의유형', public.notification_support_type_ko(new.case_type),
      '문의번호', left(new.id::text, 8),
      '문의제목', new.title
    ),
    p_button_links := jsonb_build_object('관리자 확인', admin_link),
    p_dedupe_prefix := 'support_case:' || new.id::text || ':admin_received'
  );

  return new;
end;
$$;

create or replace function public.enqueue_support_case_update_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  reporter_profile public.profiles%rowtype;
  user_link text;
begin
  if new.reporter_id is null then
    return new;
  end if;

  if old.status is not distinct from new.status
     and old.admin_note is not distinct from new.admin_note then
    return new;
  end if;

  if new.status <> 'resolved' and old.admin_note is not distinct from new.admin_note then
    return new;
  end if;

  select * into reporter_profile
  from public.profiles
  where id = new.reporter_id;

  if nullif(trim(coalesce(reporter_profile.phone, '')), '') is null then
    return new;
  end if;

  user_link := public.notification_user_url('/?route=mySupport&caseId=' || new.id::text);

  perform public.enqueue_notification(
    target_event_key := 'support_reply',
    target_template_key := 'USER_SUPPORT_REPLY_V1',
    target_recipient_role := 'user',
    target_recipient_user_id := new.reporter_id,
    target_recipient_name := coalesce(nullif(reporter_profile.full_name, ''), '이용자'),
    target_recipient_phone := reporter_profile.phone,
    target_payload := jsonb_build_object(
      '고객명', coalesce(nullif(reporter_profile.full_name, ''), '이용자'),
      '문의번호', left(new.id::text, 8),
      '문의유형', public.notification_support_type_ko(new.case_type)
    ),
    target_button_links := jsonb_build_object('마이페이지 보기', user_link),
    target_dedupe_key := 'support_case:' || new.id::text || ':reply:user:' || coalesce(new.status, 'updated')
  );

  return new;
end;
$$;

create or replace function public.enqueue_payment_intent_full_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  customer_profile public.profiles%rowtype;
  target_phone text;
  target_name text;
  user_link text;
  admin_link text;
  error_label text;
begin
  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  target_phone := coalesce(nullif(new.draft ->> 'contact_phone', ''), customer_profile.phone);
  target_name := coalesce(
    nullif(new.draft ->> 'customer_name', ''),
    nullif(customer_profile.full_name, ''),
    '이용자'
  );
  user_link := public.notification_user_url('/?route=myUsage&orderId=' || new.order_id);
  admin_link := public.notification_owner_url('/?section=payments&orderId=' || new.order_id);

  if old.refund_status is distinct from new.refund_status
     and new.refund_status in ('required', 'processing', 'refunded', 'failed')
     and nullif(trim(coalesce(target_phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'refund_status_changed',
      target_template_key := 'USER_REFUND_STATUS_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := new.customer_id,
      target_recipient_name := target_name,
      target_recipient_phone := target_phone,
      target_payload := jsonb_build_object(
        '고객명', target_name,
        '예약번호', new.order_id,
        '환불상태', public.notification_refund_status_ko(new.refund_status),
        '환불금액', public.notification_money(coalesce(new.refund_amount, new.amount, 0))
      ),
      target_button_links := jsonb_build_object('예약내역 보기', user_link),
      target_dedupe_key := 'payment_intent:' || new.id::text || ':refund:' || new.refund_status || ':user'
    );
  end if;

  if old.status is distinct from new.status and new.status = 'failed' then
    error_label := coalesce(
      nullif(new.payment_response ->> 'message', ''),
      nullif(new.payment_response ->> 'errorMessage', ''),
      nullif(new.payment_response ->> 'failureReason', ''),
      '결제 처리 실패'
    );

    perform public.enqueue_admin_notifications(
      p_event_key := 'payment_webhook_failed',
      p_template_key := 'ADMIN_PAYMENT_WEBHOOK_FAILED_V1',
      p_payload := jsonb_build_object(
        '주문번호', new.order_id,
        '실패단계', '결제 처리',
        '오류내용', error_label
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'payment_intent:' || new.id::text || ':failed'
    );
  end if;

  return new;
end;
$$;

create or replace function public.enqueue_settlement_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  owner_link text;
  admin_link text;
  settlement_label text;
  status_label text;
  dedupe_suffix text;
begin
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.payout_amount is not distinct from new.payout_amount then
    return new;
  end if;

  select * into target_business
  from public.businesses
  where id = new.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  owner_link := public.notification_owner_url('/?section=settlements&settlementId=' || new.id::text);
  admin_link := public.notification_owner_url('/?section=adminSettlements&settlementId=' || new.id::text);
  status_label := public.notification_settlement_status_ko(new.status);
  settlement_label := case new.transaction_kind
    when 'stay' then '숙소 예약'
    when 'market' then '공판장 주문'
    else '거래'
  end || ' ' || left(new.transaction_id::text, 8);
  dedupe_suffix := ':' || new.status || ':' || new.payout_amount::text;

  if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'settlement_status_changed',
      target_template_key := 'OWNER_SETTLEMENT_STATUS_V1',
      target_recipient_role := 'owner',
      target_recipient_user_id := target_business.owner_id,
      target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
      target_payload := jsonb_build_object(
        '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
        '정산건', settlement_label,
        '정산상태', status_label,
        '정산금액', public.notification_money(new.payout_amount)
      ),
      target_button_links := jsonb_build_object('정산 확인', owner_link),
      target_dedupe_key := 'settlement:' || new.id::text || ':owner' || dedupe_suffix
    );
  end if;

  perform public.enqueue_admin_notifications(
    p_event_key := 'settlement_status_changed',
    p_template_key := 'ADMIN_SETTLEMENT_STATUS_V1',
    p_payload := jsonb_build_object(
      '업장명', target_business.business_name,
      '정산상태', status_label,
      '정산금액', public.notification_money(new.payout_amount)
    ),
    p_button_links := jsonb_build_object('관리자 확인', admin_link),
    p_dedupe_prefix := 'settlement:' || new.id::text || ':admin' || dedupe_suffix
  );

  return new;
end;
$$;

create or replace function public.enqueue_availability_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  target_offering public.offerings%rowtype;
  owner_profile public.profiles%rowtype;
  owner_link text;
  admin_link text;
  date_label text;
  change_label text;
begin
  if new.source not in ('manual', 'external_ical', 'external_api') then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.start_date is not distinct from new.start_date
     and old.end_date is not distinct from new.end_date then
    return new;
  end if;

  select * into target_business
  from public.businesses
  where id = new.business_id;

  select * into target_offering
  from public.offerings
  where id = new.offering_id;

  if target_business.id is null or target_offering.id is null then
    return new;
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  owner_link := public.notification_owner_url('/?section=availability&offeringId=' || new.offering_id::text);
  admin_link := public.notification_owner_url('/?section=adminAvailability&blockId=' || new.id::text);
  date_label := public.notification_date_range(new.start_date, new.end_date);
  change_label := case
    when tg_op = 'INSERT' and new.status = 'active' then '차단 등록'
    when new.status = 'cancelled' then '차단 해제'
    else '상태 변경'
  end || ' / ' || public.notification_block_source_ko(new.source);

  if new.source in ('external_ical', 'external_api')
     and new.status = 'active'
     and nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'availability_conflict',
      target_template_key := 'OWNER_AVAILABILITY_CONFLICT_V1',
      target_recipient_role := 'owner',
      target_recipient_user_id := target_business.owner_id,
      target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
      target_payload := jsonb_build_object(
        '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
        '숙소명', target_business.business_name,
        '객실명', target_offering.name,
        '대상일정', date_label
      ),
      target_button_links := jsonb_build_object('객실 관리', owner_link),
      target_dedupe_key := 'availability:' || new.id::text || ':owner:' || new.status
    );
  end if;

  perform public.enqueue_admin_notifications(
    p_event_key := 'availability_changed',
    p_template_key := 'ADMIN_AVAILABILITY_CHANGED_V1',
    p_payload := jsonb_build_object(
      '숙소명', target_business.business_name,
      '객실명', target_offering.name,
      '대상일정', date_label,
      '변경내용', change_label
    ),
    p_button_links := jsonb_build_object('관리자 확인', admin_link),
    p_dedupe_prefix := 'availability:' || new.id::text || ':admin:' || new.status || ':' || new.start_date::text || ':' || new.end_date::text
  );

  return new;
end;
$$;

create or replace function public.enqueue_notification_failure_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_link text;
begin
  if old.status is not distinct from new.status
     or new.status <> 'failed'
     or new.template_key = 'ADMIN_NOTIFICATION_FAILED_V1' then
    return new;
  end if;

  admin_link := public.notification_owner_url('/?section=notifications&outboxId=' || new.id::text);

  perform public.enqueue_admin_notifications(
    p_event_key := 'notification_failed',
    p_template_key := 'ADMIN_NOTIFICATION_FAILED_V1',
    p_payload := jsonb_build_object(
      '수신유형', new.recipient_role,
      '템플릿명', new.template_key,
      '오류내용', coalesce(nullif(new.last_error, ''), '발송 실패')
    ),
    p_button_links := jsonb_build_object('관리자 확인', admin_link),
    p_dedupe_prefix := 'notification_outbox:' || new.id::text || ':failed'
  );

  return new;
end;
$$;

create or replace function public.enqueue_deposit_deadline_notifications(
  deadline_window_hours integer default 3
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  intent record;
  queued_count integer := 0;
  window_interval interval;
  target_name text;
  target_phone text;
  due_at timestamptz;
  detail_link text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  window_interval := (greatest(1, least(coalesce(deadline_window_hours, 3), 48))::text || ' hours')::interval;

  for intent in
    select
      pi.*,
      p.full_name as profile_name,
      p.phone as profile_phone
    from public.payment_intents pi
    left join public.profiles p on p.id = pi.customer_id
    where pi.status = 'virtual_account_issued'
      and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') > now()
      and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') <= now() + window_interval
    order by coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') asc
    limit 200
  loop
    target_phone := coalesce(nullif(intent.draft ->> 'contact_phone', ''), intent.profile_phone);
    if nullif(trim(coalesce(target_phone, '')), '') is null then
      continue;
    end if;

    target_name := coalesce(nullif(intent.draft ->> 'customer_name', ''), nullif(intent.profile_name, ''), '이용자');
    due_at := coalesce(intent.expires_at, intent.virtual_account_issued_at + interval '24 hours', intent.created_at + interval '24 hours');
    detail_link := public.notification_user_url('/?route=myUsage&orderId=' || intent.order_id);

    perform public.enqueue_notification(
      target_event_key := 'deposit_deadline',
      target_template_key := 'USER_DEPOSIT_DEADLINE_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := intent.customer_id,
      target_recipient_name := target_name,
      target_recipient_phone := target_phone,
      target_payload := jsonb_build_object(
        '고객명', target_name,
        '예약번호', intent.order_id,
        '상품명', intent.order_name,
        '입금기한', to_char(due_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'),
        '금액', public.notification_money(intent.amount)
      ),
      target_button_links := jsonb_build_object('예약/주문내역 보기', detail_link),
      target_dedupe_key := 'payment_intent:' || intent.id::text || ':deposit_deadline:user'
    );
    queued_count := queued_count + 1;
  end loop;

  return queued_count;
end;
$$;

create or replace function public.enqueue_delayed_chat_notifications(
  threshold_minutes integer default 30
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  chat record;
  queued_count integer := 0;
  threshold_interval interval;
  admin_link text;
  elapsed_minutes integer;
  bucket text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  threshold_interval := (greatest(5, least(coalesce(threshold_minutes, 30), 1440))::text || ' minutes')::interval;
  bucket := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDDHH24');

  for chat in
    select
      c.id as conversation_id,
      c.reservation_id,
      c.customer_name,
      b.business_name,
      min(m.created_at) as first_unread_at,
      count(*) as unread_count
    from public.conversations c
    join public.businesses b on b.id = c.business_id
    join public.messages m on m.conversation_id = c.id
    where m.read_at is null
      and m.created_at <= now() - threshold_interval
    group by c.id, c.reservation_id, c.customer_name, b.business_name
    order by min(m.created_at) asc
    limit 100
  loop
    admin_link := public.notification_owner_url('/?section=chat&conversationId=' || chat.conversation_id::text);
    elapsed_minutes := floor(extract(epoch from (now() - chat.first_unread_at)) / 60)::integer;

    perform public.enqueue_admin_notifications(
      p_event_key := 'chat_delayed',
      p_template_key := 'ADMIN_CHAT_DELAYED_V1',
      p_payload := jsonb_build_object(
        '대화유형', '채팅',
        '관련건', coalesce(chat.business_name, '채팅') || case when chat.reservation_id is not null then ' / 예약 ' || left(chat.reservation_id::text, 8) else '' end,
        '경과시간', elapsed_minutes::text || '분 이상'
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'chat:' || chat.conversation_id::text || ':admin_delayed:' || bucket
    );
    queued_count := queued_count + 1;
  end loop;

  return queued_count;
end;
$$;

create or replace function public.enqueue_owner_admin_notice(
  target_business_id uuid,
  notice_subject text default '운영 안내'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  notice_id uuid;
  owner_link text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  select * into target_business
  from public.businesses
  where id = target_business_id;

  if target_business.id is null then
    raise exception '업장을 찾을 수 없습니다.';
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is null then
    raise exception '알림을 받을 전화번호가 없습니다.';
  end if;

  owner_link := public.notification_owner_url('/?section=chat');

  notice_id := public.enqueue_notification(
    target_event_key := 'owner_admin_notice',
    target_template_key := 'OWNER_ADMIN_NOTICE_V1',
    target_recipient_role := 'owner',
    target_recipient_user_id := target_business.owner_id,
    target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
    target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
    target_payload := jsonb_build_object(
      '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      '관련건', coalesce(nullif(notice_subject, ''), '운영 안내')
    ),
    target_button_links := jsonb_build_object('채팅 확인', owner_link),
    target_dedupe_key := 'owner_admin_notice:' || target_business.id::text || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')
  );

  return notice_id;
end;
$$;

create or replace function public.enqueue_owner_cancel_refund_request(
  target_reservation_id uuid,
  reason text default '취소/환불 확인'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_reservation public.reservations%rowtype;
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  notice_id uuid;
  owner_link text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  select * into target_reservation
  from public.reservations
  where id = target_reservation_id;

  if target_reservation.id is null then
    raise exception '예약을 찾을 수 없습니다.';
  end if;

  select * into target_business
  from public.businesses
  where id = target_reservation.business_id;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is null then
    raise exception '알림을 받을 전화번호가 없습니다.';
  end if;

  owner_link := public.notification_owner_url('/?section=reservations&reservationId=' || target_reservation.id::text);

  notice_id := public.enqueue_notification(
    target_event_key := 'owner_cancel_refund_request',
    target_template_key := 'OWNER_CANCEL_REFUND_REQUEST_V1',
    target_recipient_role := 'owner',
    target_recipient_user_id := target_business.owner_id,
    target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
    target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
    target_payload := jsonb_build_object(
      '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      '숙소명', target_business.business_name,
      '객실명', target_reservation.offering_name,
      '예약번호', target_reservation.id::text,
      '예약일정', public.notification_date_range(
        coalesce(target_reservation.check_in_date, target_reservation.event_date),
        coalesce(target_reservation.check_out_date, target_reservation.event_date + 1)
      ),
      '확인사유', coalesce(nullif(reason, ''), '취소/환불 확인')
    ),
    target_button_links := jsonb_build_object('예약 확인', owner_link),
    target_dedupe_key := 'reservation:' || target_reservation.id::text || ':owner_cancel_refund_request:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')
  );

  return notice_id;
end;
$$;

drop trigger if exists notification_support_case_insert on public.support_cases;
create trigger notification_support_case_insert
after insert on public.support_cases
for each row execute function public.enqueue_support_case_insert_notifications();

drop trigger if exists notification_support_case_update on public.support_cases;
create trigger notification_support_case_update
after update of status, admin_note on public.support_cases
for each row execute function public.enqueue_support_case_update_notifications();

drop trigger if exists notification_payment_intent_full_update on public.payment_intents;
create trigger notification_payment_intent_full_update
after update of status, refund_status on public.payment_intents
for each row execute function public.enqueue_payment_intent_full_notifications();

drop trigger if exists notification_partner_settlement_insert on public.partner_settlements;
create trigger notification_partner_settlement_insert
after insert on public.partner_settlements
for each row execute function public.enqueue_settlement_notifications();

drop trigger if exists notification_partner_settlement_update on public.partner_settlements;
create trigger notification_partner_settlement_update
after update of status, payout_amount on public.partner_settlements
for each row execute function public.enqueue_settlement_notifications();

drop trigger if exists notification_availability_insert on public.stay_availability_blocks;
create trigger notification_availability_insert
after insert on public.stay_availability_blocks
for each row execute function public.enqueue_availability_notifications();

drop trigger if exists notification_availability_update on public.stay_availability_blocks;
create trigger notification_availability_update
after update of status, start_date, end_date on public.stay_availability_blocks
for each row execute function public.enqueue_availability_notifications();

drop trigger if exists notification_outbox_failure on public.notification_outbox;
create trigger notification_outbox_failure
after update of status on public.notification_outbox
for each row execute function public.enqueue_notification_failure_notifications();

revoke all on function public.notification_support_type_ko(text) from public;
revoke all on function public.notification_refund_status_ko(text) from public;
revoke all on function public.notification_settlement_status_ko(text) from public;
revoke all on function public.notification_block_source_ko(text) from public;
revoke all on function public.enqueue_support_case_insert_notifications() from public;
revoke all on function public.enqueue_support_case_update_notifications() from public;
revoke all on function public.enqueue_payment_intent_full_notifications() from public;
revoke all on function public.enqueue_settlement_notifications() from public;
revoke all on function public.enqueue_availability_notifications() from public;
revoke all on function public.enqueue_notification_failure_notifications() from public;
revoke all on function public.enqueue_deposit_deadline_notifications(integer) from public;
revoke all on function public.enqueue_delayed_chat_notifications(integer) from public;
revoke all on function public.enqueue_owner_admin_notice(uuid, text) from public;
revoke all on function public.enqueue_owner_cancel_refund_request(uuid, text) from public;

grant execute on function public.notification_support_type_ko(text) to authenticated, service_role;
grant execute on function public.notification_refund_status_ko(text) to authenticated, service_role;
grant execute on function public.notification_settlement_status_ko(text) to authenticated, service_role;
grant execute on function public.notification_block_source_ko(text) to authenticated, service_role;
grant execute on function public.sync_partner_settlements() to authenticated, service_role;
grant execute on function public.enqueue_deposit_deadline_notifications(integer) to authenticated, service_role;
grant execute on function public.enqueue_delayed_chat_notifications(integer) to authenticated, service_role;
grant execute on function public.enqueue_owner_admin_notice(uuid, text) to authenticated, service_role;
grant execute on function public.enqueue_owner_cancel_refund_request(uuid, text) to authenticated, service_role;
