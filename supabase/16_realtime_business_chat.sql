-- moTF 4단계: 이용자·사장님·운영팀 실제 채팅 연결

create index if not exists conversations_customer_last_idx
on public.conversations(customer_id, last_message_at desc);

create or replace function public.start_business_conversation(
  target_business_id uuid,
  target_reservation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_id uuid;
  customer_profile public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into customer_profile
  from public.profiles
  where id = auth.uid()
    and role = 'user'
    and status = 'approved';

  if customer_profile.id is null then
    raise exception '승인된 이용자 계정만 채팅을 시작할 수 있습니다.';
  end if;

  if not exists (
    select 1 from public.businesses
    where id = target_business_id
      and approval_status = 'approved'
  ) then
    raise exception '이용 가능한 업장을 찾을 수 없습니다.';
  end if;

  select id into result_id
  from public.conversations
  where business_id = target_business_id
    and customer_id = auth.uid()
    and reservation_id is not distinct from target_reservation_id
  order by created_at desc
  limit 1;

  if result_id is null then
    insert into public.conversations (
      business_id,
      customer_id,
      reservation_id,
      customer_name,
      group_name
    ) values (
      target_business_id,
      auth.uid(),
      target_reservation_id,
      coalesce(nullif(customer_profile.full_name, ''), nullif(customer_profile.email, ''), '이용자'),
      nullif(customer_profile.organization, '')
    )
    returning id into result_id;
  end if;

  return result_id;
end;
$$;

create or replace function public.send_chat_message(
  target_conversation_id uuid,
  message_body text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  sender_profile public.profiles%rowtype;
  target_conversation public.conversations%rowtype;
  result_id uuid;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if nullif(btrim(message_body), '') is null or char_length(btrim(message_body)) > 4000 then
    raise exception '메시지는 1자 이상 4000자 이하로 입력해주세요.';
  end if;

  select * into sender_profile
  from public.profiles
  where id = auth.uid()
    and status = 'approved';

  if sender_profile.id is null then
    raise exception '이용 가능한 계정이 아닙니다.';
  end if;

  select * into target_conversation
  from public.conversations
  where id = target_conversation_id;

  if target_conversation.id is null then
    raise exception '대화를 찾을 수 없습니다.';
  end if;

  if not (
    target_conversation.customer_id = auth.uid()
    or public.owns_business(target_conversation.business_id)
    or public.is_admin()
  ) then
    raise exception '이 대화에 메시지를 보낼 권한이 없습니다.';
  end if;

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_role,
    body
  ) values (
    target_conversation_id,
    auth.uid(),
    sender_profile.role,
    btrim(message_body)
  )
  returning id into result_id;

  update public.conversations
  set last_message_at = now()
  where id = target_conversation_id;

  return result_id;
end;
$$;

revoke all on function public.start_business_conversation(uuid, uuid) from public;
revoke all on function public.send_chat_message(uuid, text) from public;
grant execute on function public.start_business_conversation(uuid, uuid) to authenticated;
grant execute on function public.send_chat_message(uuid, text) to authenticated;

-- 메시지 변경을 로그인한 참여자 화면에 실시간 전달
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversations'
  ) then
    alter publication supabase_realtime add table public.conversations;
  end if;
end;
$$;
