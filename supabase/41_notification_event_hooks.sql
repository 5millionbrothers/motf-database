-- moTF notification event hooks.
-- Queues mock/Alimtalk notifications when reservations, orders, and chat messages change.

create or replace function public.notification_money(amount integer)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(to_char(amount, 'FM999,999,999,999'), '0') || '원';
$$;

create or replace function public.notification_date_range(start_date date, end_date date)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when start_date is null then ''
    when end_date is null or end_date = start_date then start_date::text
    else start_date::text || ' ~ ' || end_date::text
  end;
$$;

create or replace function public.notification_user_url(path text default '')
returns text
language sql
stable
set search_path = ''
as $$
  select 'https://motf.co.kr' || case when coalesce(path, '') like '/%' then coalesce(path, '') else '/' || coalesce(path, '') end;
$$;

create or replace function public.notification_owner_url(path text default '')
returns text
language sql
stable
set search_path = ''
as $$
  select 'https://motfowner.co.kr' || case when coalesce(path, '') like '/%' then coalesce(path, '') else '/' || coalesce(path, '') end;
$$;

create or replace function public.notification_status_ko(status_value text)
returns text
language sql
stable
set search_path = ''
as $$
  select case status_value
    when 'pending' then '요청 접수'
    when 'confirmed' then '확정'
    when 'rejected' then '취소'
    when 'cancelled' then '취소'
    when 'completed' then '이용 완료'
    when 'refund_required' then '환불 필요'
    when 'refund_processing' then '환불 처리중'
    when 'refunded' then '환불 완료'
    when 'refund_failed' then '환불 실패'
    else coalesce(status_value, '')
  end;
$$;

create or replace function public.enqueue_admin_notifications(
  p_event_key text,
  p_template_key text,
  p_payload jsonb default '{}'::jsonb,
  p_button_links jsonb default '{}'::jsonb,
  p_dedupe_prefix text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_profile record;
  queued_count integer := 0;
begin
  for admin_profile in
    select id, full_name, phone
    from public.profiles
    where role = 'admin'
      and status = 'approved'
      and nullif(trim(coalesce(phone, '')), '') is not null
  loop
    perform public.enqueue_notification(
      target_event_key := p_event_key,
      target_template_key := p_template_key,
      target_recipient_role := 'admin',
      target_recipient_user_id := admin_profile.id,
      target_recipient_name := coalesce(nullif(admin_profile.full_name, ''), '모티프 운영팀'),
      target_recipient_phone := admin_profile.phone,
      target_payload := coalesce(p_payload, '{}'::jsonb),
      target_button_links := coalesce(p_button_links, '{}'::jsonb),
      target_dedupe_key := coalesce(p_dedupe_prefix, p_event_key || ':' || p_template_key) || ':admin:' || admin_profile.id::text
    );
    queued_count := queued_count + 1;
  end loop;

  return queued_count;
end;
$$;

create or replace function public.enqueue_reservation_insert_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  customer_profile public.profiles%rowtype;
  reservation_range text;
  user_link text;
  owner_detail_link text;
  owner_accept_link text;
  owner_cancel_link text;
begin
  select * into target_business
  from public.businesses
  where id = new.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  reservation_range := public.notification_date_range(
    coalesce(new.check_in_date, new.event_date),
    coalesce(new.check_out_date, new.event_date + 1)
  );
  user_link := public.notification_user_url('/?route=myUsage&reservationId=' || new.id::text);
  owner_detail_link := public.notification_owner_url('/?section=reservations&reservationId=' || new.id::text);
  owner_accept_link := public.notification_owner_url('/?quickAction=reservation_confirm&reservationId=' || new.id::text);
  owner_cancel_link := public.notification_owner_url('/?quickAction=reservation_cancel&reservationId=' || new.id::text);

  if nullif(trim(coalesce(new.contact_phone, customer_profile.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'reservation_requested',
      target_template_key := 'USER_RESERVATION_REQUESTED_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := new.customer_id,
      target_recipient_name := coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
      target_recipient_phone := coalesce(nullif(new.contact_phone, ''), customer_profile.phone),
      target_payload := jsonb_build_object(
        '고객명', coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        '숙소명', target_business.business_name,
        '객실명', new.offering_name,
        '예약일정', reservation_range,
        '예약번호', new.id::text,
        '금액', public.notification_money(new.total_amount)
      ),
      target_button_links := jsonb_build_object('예약내역 보기', user_link),
      target_dedupe_key := 'reservation:' || new.id::text || ':requested:user'
    );
  end if;

  if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'reservation_requested',
      target_template_key := 'OWNER_RESERVATION_REQUEST_V1',
      target_recipient_role := 'owner',
      target_recipient_user_id := target_business.owner_id,
      target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
      target_payload := jsonb_build_object(
        '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
        '숙소명', target_business.business_name,
        '객실명', new.offering_name,
        '예약일정', reservation_range,
        '예약번호', new.id::text,
        '인원', coalesce(new.guest_count::text, '-')
      ),
      target_button_links := jsonb_build_object(
        '예약 확인', owner_detail_link,
        '수락 처리', owner_accept_link,
        '취소 처리', owner_cancel_link
      ),
      target_dedupe_key := 'reservation:' || new.id::text || ':requested:owner'
    );
  end if;

  return new;
end;
$$;

create or replace function public.enqueue_payment_intent_update_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  customer_profile public.profiles%rowtype;
  target_phone text;
  target_name text;
  detail_link text;
  bank_name text;
  account_number text;
  due_label text;
begin
  if old.status is not distinct from new.status or new.status <> 'virtual_account_issued' then
    return new;
  end if;

  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  target_phone := coalesce(nullif(new.draft ->> 'contact_phone', ''), customer_profile.phone);
  if nullif(trim(coalesce(target_phone, '')), '') is null then
    return new;
  end if;

  target_name := coalesce(
    nullif(new.draft ->> 'customer_name', ''),
    nullif(customer_profile.full_name, ''),
    '이용자'
  );
  detail_link := public.notification_user_url('/?route=myUsage&orderId=' || new.order_id);
  bank_name := coalesce(
    nullif(new.virtual_account ->> 'bankName', ''),
    nullif(new.virtual_account ->> 'bank_name', ''),
    nullif(new.virtual_account ->> 'bank', ''),
    nullif(new.virtual_account ->> 'bankCode', ''),
    '은행 확인 필요'
  );
  account_number := coalesce(
    nullif(new.virtual_account ->> 'accountNumber', ''),
    nullif(new.virtual_account ->> 'account_number', ''),
    nullif(new.virtual_account ->> 'accountNo', ''),
    nullif(new.virtual_account ->> 'account', ''),
    '계좌 확인 필요'
  );
  due_label := coalesce(
    nullif(new.virtual_account ->> 'dueDate', ''),
    nullif(new.virtual_account ->> 'due_date', ''),
    nullif(new.virtual_account ->> 'expiredAt', ''),
    nullif(new.virtual_account ->> 'expiresAt', ''),
    new.expires_at::text
  );

  perform public.enqueue_notification(
    target_event_key := 'virtual_account_issued',
    target_template_key := 'USER_VA_ISSUED_V1',
    target_recipient_role := 'user',
    target_recipient_user_id := new.customer_id,
    target_recipient_name := target_name,
    target_recipient_phone := target_phone,
    target_payload := jsonb_build_object(
      '고객명', target_name,
      '상품명', new.order_name,
      '예약번호', new.order_id,
      '은행명', bank_name,
      '계좌번호', account_number,
      '입금기한', due_label,
      '금액', public.notification_money(new.amount)
    ),
    target_button_links := jsonb_build_object('예약/주문내역 보기', detail_link),
    target_dedupe_key := 'payment_intent:' || new.id::text || ':virtual_account:user'
  );

  return new;
end;
$$;

create or replace function public.enqueue_reservation_update_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  customer_profile public.profiles%rowtype;
  reservation_range text;
  user_link text;
  admin_link text;
  current_reason text;
begin
  select * into target_business
  from public.businesses
  where id = new.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  reservation_range := public.notification_date_range(
    coalesce(new.check_in_date, new.event_date),
    coalesce(new.check_out_date, new.event_date + 1)
  );
  user_link := public.notification_user_url('/?route=myUsage&reservationId=' || new.id::text);
  admin_link := public.notification_owner_url('/?section=adminReservations&reservationId=' || new.id::text);
  current_reason := coalesce(nullif(new.reject_reason, ''), nullif(new.refund_reason, ''), '일정 또는 객실 사정');

  if old.status is distinct from new.status then
    if new.status = 'confirmed' and nullif(trim(coalesce(new.contact_phone, customer_profile.phone, '')), '') is not null then
      perform public.enqueue_notification(
        target_event_key := 'reservation_confirmed',
        target_template_key := 'USER_RESERVATION_CONFIRMED_V1',
        target_recipient_role := 'user',
        target_recipient_user_id := new.customer_id,
        target_recipient_name := coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        target_recipient_phone := coalesce(nullif(new.contact_phone, ''), customer_profile.phone),
        target_payload := jsonb_build_object(
          '고객명', coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
          '숙소명', target_business.business_name,
          '객실명', new.offering_name,
          '예약일정', reservation_range,
          '예약번호', new.id::text
        ),
        target_button_links := jsonb_build_object('예약내역 보기', user_link),
        target_dedupe_key := 'reservation:' || new.id::text || ':confirmed:user'
      );
    elsif new.status in ('rejected', 'cancelled') and nullif(trim(coalesce(new.contact_phone, customer_profile.phone, '')), '') is not null then
      perform public.enqueue_notification(
        target_event_key := 'reservation_cancelled',
        target_template_key := 'USER_RESERVATION_CANCELLED_V1',
        target_recipient_role := 'user',
        target_recipient_user_id := new.customer_id,
        target_recipient_name := coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        target_recipient_phone := coalesce(nullif(new.contact_phone, ''), customer_profile.phone),
        target_payload := jsonb_build_object(
          '고객명', coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
          '숙소명', target_business.business_name,
          '예약번호', new.id::text,
          '취소사유', current_reason,
          '환불금액', public.notification_money(coalesce(new.refund_amount, new.total_amount, 0))
        ),
        target_button_links := jsonb_build_object('예약내역 보기', user_link),
        target_dedupe_key := 'reservation:' || new.id::text || ':cancelled:user'
      );
    end if;

    if new.status in ('confirmed', 'rejected', 'cancelled') then
      perform public.enqueue_admin_notifications(
        p_event_key := 'reservation_status_changed',
        p_template_key := 'ADMIN_RESERVATION_STATUS_V1',
        p_payload := jsonb_build_object(
          '숙소명', target_business.business_name,
          '예약번호', new.id::text,
          '예약상태', public.notification_status_ko(new.status)
        ),
        p_button_links := jsonb_build_object('관리자 확인', admin_link),
        p_dedupe_prefix := 'reservation:' || new.id::text || ':status:' || new.status
      );
    end if;
  end if;

  if old.refund_status is distinct from new.refund_status and new.refund_status = 'required' then
    perform public.enqueue_admin_notifications(
      p_event_key := 'refund_required',
      p_template_key := 'ADMIN_REFUND_REQUIRED_V1',
      p_payload := jsonb_build_object(
        '거래번호', new.id::text,
        '환불금액', public.notification_money(coalesce(new.refund_amount, new.total_amount, 0)),
        '환불사유', current_reason
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'reservation:' || new.id::text || ':refund_required'
    );
  elsif old.refund_status is distinct from new.refund_status and new.refund_status = 'failed' then
    perform public.enqueue_admin_notifications(
      p_event_key := 'refund_failed',
      p_template_key := 'ADMIN_REFUND_FAILED_V1',
      p_payload := jsonb_build_object(
        '거래번호', new.id::text,
        '환불금액', public.notification_money(coalesce(new.refund_amount, new.total_amount, 0)),
        '오류내용', coalesce(nullif(new.refund_reason, ''), '환불 상태 확인 필요')
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'reservation:' || new.id::text || ':refund_failed'
    );
  end if;

  return new;
end;
$$;

create or replace function public.enqueue_market_order_insert_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  customer_profile public.profiles%rowtype;
  user_link text;
  owner_link text;
  admin_link text;
  pickup_label text;
begin
  select * into target_business
  from public.businesses
  where id = new.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  user_link := public.notification_user_url('/?route=myUsage&orderId=' || new.id::text);
  owner_link := public.notification_owner_url('/?section=orders&orderId=' || new.id::text);
  admin_link := public.notification_owner_url('/?section=adminOrders&orderId=' || new.id::text);
  pickup_label := coalesce(new.pickup_place, '수령 장소 확인 필요') || ' / ' || coalesce(new.pickup_time::text, '시간 확인 필요');

  if nullif(trim(coalesce(new.contact_phone, customer_profile.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'market_order_received',
      target_template_key := 'USER_ORDER_RECEIVED_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := new.customer_id,
      target_recipient_name := coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
      target_recipient_phone := coalesce(nullif(new.contact_phone, ''), customer_profile.phone),
      target_payload := jsonb_build_object(
        '고객명', coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        '공판장명', target_business.business_name,
        '주문번호', new.id::text,
        '수령일시', pickup_label,
        '금액', public.notification_money(new.total_amount)
      ),
      target_button_links := jsonb_build_object('주문내역 보기', user_link),
      target_dedupe_key := 'market_order:' || new.id::text || ':received:user'
    );
  end if;

  if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'market_order_received',
      target_template_key := 'OWNER_ORDER_REQUEST_V1',
      target_recipient_role := 'owner',
      target_recipient_user_id := target_business.owner_id,
      target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
      target_payload := jsonb_build_object(
        '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
        '공판장명', target_business.business_name,
        '주문번호', new.id::text,
        '수령일시', pickup_label
      ),
      target_button_links := jsonb_build_object('주문 확인', owner_link),
      target_dedupe_key := 'market_order:' || new.id::text || ':received:owner'
    );
  end if;

  perform public.enqueue_admin_notifications(
    p_event_key := 'market_order_received',
    p_template_key := 'ADMIN_NEW_ORDER_V1',
    p_payload := jsonb_build_object(
      '공판장명', target_business.business_name,
      '주문번호', new.id::text,
      '주문금액', public.notification_money(new.total_amount)
    ),
    p_button_links := jsonb_build_object('관리자 확인', admin_link),
    p_dedupe_prefix := 'market_order:' || new.id::text || ':admin_new_order'
  );

  return new;
end;
$$;

create or replace function public.enqueue_market_order_update_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  customer_profile public.profiles%rowtype;
  user_link text;
  admin_link text;
  current_reason text;
begin
  select * into target_business
  from public.businesses
  where id = new.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into customer_profile
  from public.profiles
  where id = new.customer_id;

  user_link := public.notification_user_url('/?route=myUsage&orderId=' || new.id::text);
  admin_link := public.notification_owner_url('/?section=adminOrders&orderId=' || new.id::text);
  current_reason := coalesce(nullif(new.reject_reason, ''), nullif(new.refund_reason, ''), '주문 처리 상태 확인 필요');

  if old.status is distinct from new.status and new.status in ('confirmed', 'rejected', 'cancelled', 'completed')
     and nullif(trim(coalesce(new.contact_phone, customer_profile.phone, '')), '') is not null then
    perform public.enqueue_notification(
      target_event_key := 'market_order_status_changed',
      target_template_key := 'USER_ORDER_STATUS_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := new.customer_id,
      target_recipient_name := coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
      target_recipient_phone := coalesce(nullif(new.contact_phone, ''), customer_profile.phone),
      target_payload := jsonb_build_object(
        '고객명', coalesce(nullif(new.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        '공판장명', target_business.business_name,
        '주문번호', new.id::text,
        '주문상태', public.notification_status_ko(new.status)
      ),
      target_button_links := jsonb_build_object('주문내역 보기', user_link),
      target_dedupe_key := 'market_order:' || new.id::text || ':status:' || new.status || ':user'
    );
  end if;

  if old.refund_status is distinct from new.refund_status and new.refund_status = 'required' then
    perform public.enqueue_admin_notifications(
      p_event_key := 'refund_required',
      p_template_key := 'ADMIN_REFUND_REQUIRED_V1',
      p_payload := jsonb_build_object(
        '거래번호', new.id::text,
        '환불금액', public.notification_money(coalesce(new.refund_amount, new.total_amount, 0)),
        '환불사유', current_reason
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'market_order:' || new.id::text || ':refund_required'
    );
  elsif old.refund_status is distinct from new.refund_status and new.refund_status = 'failed' then
    perform public.enqueue_admin_notifications(
      p_event_key := 'refund_failed',
      p_template_key := 'ADMIN_REFUND_FAILED_V1',
      p_payload := jsonb_build_object(
        '거래번호', new.id::text,
        '환불금액', public.notification_money(coalesce(new.refund_amount, new.total_amount, 0)),
        '오류내용', coalesce(nullif(new.refund_reason, ''), '환불 상태 확인 필요')
      ),
      p_button_links := jsonb_build_object('관리자 확인', admin_link),
      p_dedupe_prefix := 'market_order:' || new.id::text || ':refund_failed'
    );
  end if;

  return new;
end;
$$;

create or replace function public.enqueue_chat_message_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_conversation public.conversations%rowtype;
  target_business public.businesses%rowtype;
  owner_profile public.profiles%rowtype;
  customer_profile public.profiles%rowtype;
  sender_profile public.profiles%rowtype;
  related_label text;
  cooldown_bucket text;
  chat_link text;
begin
  select * into target_conversation
  from public.conversations
  where id = new.conversation_id;

  if target_conversation.id is null then
    return new;
  end if;

  select * into target_business
  from public.businesses
  where id = target_conversation.business_id;

  if target_business.id is null then
    return new;
  end if;

  select * into owner_profile
  from public.profiles
  where id = target_business.owner_id;

  select * into customer_profile
  from public.profiles
  where id = target_conversation.customer_id;

  select * into sender_profile
  from public.profiles
  where id = new.sender_id;

  related_label := case
    when target_conversation.reservation_id is not null then '예약 ' || left(target_conversation.reservation_id::text, 8)
    else target_business.business_name
  end;
  cooldown_bucket := floor(extract(epoch from new.created_at) / 300)::text;

  if new.sender_id = target_conversation.customer_id then
    if nullif(trim(coalesce(owner_profile.phone, target_business.phone, '')), '') is null then
      return new;
    end if;

    chat_link := public.notification_owner_url('/?section=chat&conversationId=' || target_conversation.id::text);
    perform public.enqueue_notification(
      target_event_key := 'chat_received',
      target_template_key := 'OWNER_CHAT_RECEIVED_V1',
      target_recipient_role := 'owner',
      target_recipient_user_id := target_business.owner_id,
      target_recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
      target_recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone),
      target_payload := jsonb_build_object(
        '사장님명', coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님'),
        '고객명', coalesce(nullif(target_conversation.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        '관련건', related_label
      ),
      target_button_links := jsonb_build_object('채팅 확인', chat_link),
      target_dedupe_key := 'chat:' || target_conversation.id::text || ':owner:' || cooldown_bucket
    );
  elsif new.sender_id = target_business.owner_id or new.sender_role in ('partner', 'admin') then
    if nullif(trim(coalesce(customer_profile.phone, '')), '') is null then
      return new;
    end if;

    chat_link := public.notification_user_url('/?route=chat&conversationId=' || target_conversation.id::text);
    perform public.enqueue_notification(
      target_event_key := 'chat_received',
      target_template_key := 'USER_CHAT_RECEIVED_V1',
      target_recipient_role := 'user',
      target_recipient_user_id := target_conversation.customer_id,
      target_recipient_name := coalesce(nullif(target_conversation.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
      target_recipient_phone := customer_profile.phone,
      target_payload := jsonb_build_object(
        '고객명', coalesce(nullif(target_conversation.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
        '상대명', coalesce(nullif(target_business.business_name, ''), nullif(sender_profile.full_name, ''), 'moTF'),
        '관련건', related_label
      ),
      target_button_links := jsonb_build_object('채팅 확인', chat_link),
      target_dedupe_key := 'chat:' || target_conversation.id::text || ':user:' || cooldown_bucket
    );
  end if;

  return new;
end;
$$;

drop trigger if exists notification_reservation_insert on public.reservations;
create trigger notification_reservation_insert
after insert on public.reservations
for each row execute function public.enqueue_reservation_insert_notifications();

drop trigger if exists notification_payment_intent_update on public.payment_intents;
create trigger notification_payment_intent_update
after update of status on public.payment_intents
for each row execute function public.enqueue_payment_intent_update_notifications();

drop trigger if exists notification_reservation_update on public.reservations;
create trigger notification_reservation_update
after update of status, refund_status on public.reservations
for each row execute function public.enqueue_reservation_update_notifications();

drop trigger if exists notification_market_order_insert on public.market_orders;
create trigger notification_market_order_insert
after insert on public.market_orders
for each row execute function public.enqueue_market_order_insert_notifications();

drop trigger if exists notification_market_order_update on public.market_orders;
create trigger notification_market_order_update
after update of status, refund_status on public.market_orders
for each row execute function public.enqueue_market_order_update_notifications();

drop trigger if exists notification_message_insert on public.messages;
create trigger notification_message_insert
after insert on public.messages
for each row execute function public.enqueue_chat_message_notifications();

revoke all on function public.notification_money(integer) from public;
revoke all on function public.notification_date_range(date, date) from public;
revoke all on function public.notification_user_url(text) from public;
revoke all on function public.notification_owner_url(text) from public;
revoke all on function public.notification_status_ko(text) from public;
revoke all on function public.enqueue_admin_notifications(text, text, jsonb, jsonb, text) from public;
revoke all on function public.enqueue_reservation_insert_notifications() from public;
revoke all on function public.enqueue_payment_intent_update_notifications() from public;
revoke all on function public.enqueue_reservation_update_notifications() from public;
revoke all on function public.enqueue_market_order_insert_notifications() from public;
revoke all on function public.enqueue_market_order_update_notifications() from public;
revoke all on function public.enqueue_chat_message_notifications() from public;

grant execute on function public.notification_money(integer) to authenticated, service_role;
grant execute on function public.notification_date_range(date, date) to authenticated, service_role;
grant execute on function public.notification_user_url(text) to authenticated, service_role;
grant execute on function public.notification_owner_url(text) to authenticated, service_role;
grant execute on function public.notification_status_ko(text) to authenticated, service_role;
grant execute on function public.enqueue_admin_notifications(text, text, jsonb, jsonb, text) to authenticated, service_role;
