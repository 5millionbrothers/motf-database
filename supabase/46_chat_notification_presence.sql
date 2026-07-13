-- moTF chat Alimtalk cost control.
-- Send the first unread message immediately, suppress notifications while the
-- recipient is viewing the conversation, and reset after the conversation is read.

create table if not exists public.chat_notification_state (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  recipient_user_id uuid not null references public.profiles(id) on delete cascade,
  active_until timestamptz,
  last_read_at timestamptz,
  last_notified_message_id uuid references public.messages(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (conversation_id, recipient_user_id)
);

create index if not exists chat_notification_state_active_idx
on public.chat_notification_state(active_until)
where active_until is not null;

alter table public.chat_notification_state enable row level security;
revoke all on table public.chat_notification_state from anon, authenticated;

create or replace function public.set_chat_presence(
  target_conversation_id uuid,
  is_active boolean default true
)
returns void
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
    from public.conversations c
    join public.businesses b on b.id = c.business_id
    where c.id = target_conversation_id
      and (
        c.customer_id = auth.uid()
        or b.owner_id = auth.uid()
        or public.is_admin()
      )
  ) then
    raise exception '이 대화에 접근할 권한이 없습니다.';
  end if;

  insert into public.chat_notification_state (
    conversation_id,
    recipient_user_id,
    active_until,
    updated_at
  ) values (
    target_conversation_id,
    auth.uid(),
    case when is_active then now() + interval '75 seconds' else now() end,
    now()
  )
  on conflict (conversation_id, recipient_user_id) do update
  set
    active_until = excluded.active_until,
    updated_at = now();
end;
$$;

create or replace function public.mark_conversation_read(
  target_conversation_id uuid
)
returns void
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
    from public.conversations c
    join public.businesses b on b.id = c.business_id
    where c.id = target_conversation_id
      and (
        c.customer_id = auth.uid()
        or b.owner_id = auth.uid()
        or public.is_admin()
      )
  ) then
    raise exception '이 대화를 확인할 권한이 없습니다.';
  end if;

  update public.messages
  set read_at = now()
  where conversation_id = target_conversation_id
    and sender_id <> auth.uid()
    and read_at is null;

  insert into public.chat_notification_state (
    conversation_id,
    recipient_user_id,
    active_until,
    last_read_at,
    last_notified_message_id,
    updated_at
  ) values (
    target_conversation_id,
    auth.uid(),
    now() + interval '75 seconds',
    now(),
    null,
    now()
  )
  on conflict (conversation_id, recipient_user_id) do update
  set
    active_until = excluded.active_until,
    last_read_at = excluded.last_read_at,
    last_notified_message_id = null,
    updated_at = now();
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
  recipient_state public.chat_notification_state%rowtype;
  recipient_id uuid;
  recipient_role text;
  recipient_name text;
  recipient_phone text;
  template_key text;
  button_name text;
  related_label text;
  chat_link text;
  message_payload jsonb;
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
    when target_conversation.reservation_id is not null
      then '예약 ' || left(target_conversation.reservation_id::text, 8)
    else target_business.business_name
  end;

  if new.sender_id = target_conversation.customer_id then
    recipient_id := target_business.owner_id;
    recipient_role := 'owner';
    recipient_name := coalesce(nullif(owner_profile.full_name, ''), target_business.representative_name, '사장님');
    recipient_phone := coalesce(nullif(owner_profile.phone, ''), target_business.phone);
    template_key := 'OWNER_CHAT_RECEIVED_V1';
    button_name := '문의 확인';
    chat_link := public.notification_owner_url('/?section=chat&conversationId=' || target_conversation.id::text);
    message_payload := jsonb_build_object(
      '사장님명', recipient_name,
      '고객명', coalesce(nullif(target_conversation.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자'),
      '관련건', related_label
    );
  elsif new.sender_id = target_business.owner_id or new.sender_role in ('partner', 'admin') then
    recipient_id := target_conversation.customer_id;
    recipient_role := 'user';
    recipient_name := coalesce(nullif(target_conversation.customer_name, ''), nullif(customer_profile.full_name, ''), '이용자');
    recipient_phone := customer_profile.phone;
    template_key := 'USER_CHAT_RECEIVED_V1';
    button_name := '답변 확인';
    chat_link := public.notification_user_url('/?route=chat&conversationId=' || target_conversation.id::text);
    message_payload := jsonb_build_object(
      '고객명', recipient_name,
      '상대명', coalesce(nullif(target_business.business_name, ''), nullif(sender_profile.full_name, ''), 'moTF'),
      '관련건', related_label
    );
  else
    return new;
  end if;

  if recipient_id is null or nullif(trim(coalesce(recipient_phone, '')), '') is null then
    return new;
  end if;

  insert into public.chat_notification_state (
    conversation_id,
    recipient_user_id,
    updated_at
  ) values (
    target_conversation.id,
    recipient_id,
    now()
  )
  on conflict (conversation_id, recipient_user_id) do nothing;

  select * into recipient_state
  from public.chat_notification_state
  where conversation_id = target_conversation.id
    and recipient_user_id = recipient_id
  for update;

  if recipient_state.active_until is not null and recipient_state.active_until > now() then
    update public.messages
    set read_at = coalesce(read_at, now())
    where conversation_id = target_conversation.id
      and sender_id <> recipient_id
      and read_at is null;

    update public.chat_notification_state
    set
      last_read_at = now(),
      last_notified_message_id = null,
      updated_at = now()
    where conversation_id = target_conversation.id
      and recipient_user_id = recipient_id;

    return new;
  end if;

  -- One immediate Alimtalk per unread conversation batch. Reading the chat
  -- clears last_notified_message_id and allows the next batch to notify again.
  if recipient_state.last_notified_message_id is not null then
    return new;
  end if;

  perform public.enqueue_notification(
    target_event_key := 'chat_received',
    target_template_key := template_key,
    target_recipient_role := recipient_role,
    target_recipient_user_id := recipient_id,
    target_recipient_name := recipient_name,
    target_recipient_phone := recipient_phone,
    target_payload := message_payload,
    target_button_links := jsonb_build_object(button_name, chat_link),
    target_dedupe_key := 'chat:' || target_conversation.id::text || ':' || recipient_id::text || ':' || new.id::text
  );

  update public.chat_notification_state
  set
    last_notified_message_id = new.id,
    updated_at = now()
  where conversation_id = target_conversation.id
    and recipient_user_id = recipient_id;

  return new;
end;
$$;

-- Replace rejected broad chat copy with action-based inquiry/reply copy.
update public.notification_templates
set
  title = '업장 이용 문의가 도착했습니다',
  body = E'[moTF] 고객 문의 안내\n\n#{사장님명}님, moTF 이용자가 업장 이용에 관한 문의를 남겼습니다.\n\n문의 고객: #{고객명}\n문의 대상: #{관련건}\n\n고객님이 직접 남긴 문의입니다.\n채팅에서 문의 내용을 확인해주세요.',
  buttons = '[{"name":"문의 확인","type":"WL"}]'::jsonb,
  status = 'submitted',
  memo = '이용자가 업장에 직접 문의한 직후 첫 미확인 메시지만 즉시 발송',
  updated_at = now()
where template_key = 'OWNER_CHAT_RECEIVED_V1';

update public.notification_templates
set
  title = '문의하신 내용에 답변이 도착했습니다',
  body = E'[moTF] 문의 답변 안내\n\n#{고객명}님이 moTF에서 남긴 업장 이용 문의에 답변이 등록되었습니다.\n\n답변 업체: #{상대명}\n문의 대상: #{관련건}\n\n고객님이 직접 남긴 문의에 대한 답변입니다.\n채팅에서 답변 내용을 확인해주세요.',
  buttons = '[{"name":"답변 확인","type":"WL"}]'::jsonb,
  status = 'submitted',
  memo = '이용자가 먼저 남긴 문의에 답변한 직후 첫 미확인 메시지만 즉시 발송',
  updated_at = now()
where template_key = 'USER_CHAT_RECEIVED_V1';

-- Keep historical rows intact, but prevent the removed dealer template from being used.
update public.notification_templates
set
  status = 'paused',
  memo = '알리고 등록 대상에서 삭제되어 사용 중지',
  updated_at = now()
where template_key = 'OWNER_ADMIN_NOTICE_V1';

drop function if exists public.enqueue_owner_admin_notice(uuid, text);

-- Old queued chat messages were created under the rejected broad template/cooldown rule.
update public.notification_outbox
set
  status = 'cancelled',
  last_error = '새 채팅 알림 정책 적용으로 기존 대기 건 취소',
  updated_at = now()
where event_key = 'chat_received'
  and status = 'queued';

revoke all on function public.set_chat_presence(uuid, boolean) from public;
revoke all on function public.mark_conversation_read(uuid) from public;
grant execute on function public.set_chat_presence(uuid, boolean) to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
