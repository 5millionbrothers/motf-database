-- Shared organization chats retain personal threads and actual message authors.
begin;
alter table public.conversations add column if not exists organization_id uuid references public.organizations(id);
alter table public.messages add column if not exists sender_name text;
create unique index if not exists organization_business_chat_unique on public.conversations(organization_id,business_id) where organization_id is not null;
create index if not exists organization_chat_last on public.conversations(organization_id,last_message_at desc);

create or replace function public.can_access_conversation(target_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.status='approved')
 and exists(select 1 from public.conversations c where c.id=target_id and (
 public.is_admin() or public.owns_business(c.business_id)
 or case when c.organization_id is null then c.customer_id=auth.uid() else public.is_organization_member(c.organization_id) end));
$$;
revoke all on function public.can_access_conversation(uuid) from public;
grant execute on function public.can_access_conversation(uuid) to authenticated,service_role;
drop policy if exists conversations_read on public.conversations;
create policy conversations_read on public.conversations for select to authenticated using(public.can_access_conversation(id));
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated using(public.can_access_conversation(conversation_id));
drop policy if exists conversations_user_insert on public.conversations;
drop policy if exists messages_participant_insert on public.messages;

create or replace function public.freeze_conversation_account()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.organization_id is distinct from old.organization_id or new.customer_id is distinct from old.customer_id or new.business_id is distinct from old.business_id then
 raise exception '대화의 개인/단체 소속과 업장은 변경할 수 없습니다.'; end if;
 return new;
end;
$$;
drop trigger if exists freeze_conversation_account on public.conversations;
create trigger freeze_conversation_account before update on public.conversations for each row execute function public.freeze_conversation_account();

create or replace function public.start_organization_business_conversation(
 target_organization_id uuid,target_business_id uuid,target_reservation_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid; person public.profiles%rowtype; org public.organizations%rowtype;
begin
 if not public.is_organization_member(target_organization_id) then raise exception '단체 채팅 권한이 없습니다.'; end if;
 select * into person from public.profiles where id=auth.uid();
 select * into org from public.organizations where id=target_organization_id;
 if not exists(select 1 from public.businesses where id=target_business_id and approval_status='approved') then raise exception '이용 가능한 업장이 없습니다.'; end if;
 if target_reservation_id is not null and not exists(select 1 from public.reservations where id=target_reservation_id and business_id=target_business_id and organization_id=target_organization_id) then raise exception '단체 예약과 채팅 업장이 일치하지 않습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text||':'||target_business_id::text,0));
 select id into result_id from public.conversations where organization_id=target_organization_id and business_id=target_business_id;
 if result_id is null then
 insert into public.conversations(business_id,customer_id,organization_id,reservation_id,customer_name,group_name)
 values(target_business_id,auth.uid(),target_organization_id,target_reservation_id,coalesce(nullif(person.full_name,''),'담당자'),org.name) returning id into result_id;
 else
 update public.conversations set group_name=org.name,reservation_id=coalesce(reservation_id,target_reservation_id)
 where id=result_id and (group_name is distinct from org.name or (reservation_id is null and target_reservation_id is not null));
 end if;
 return result_id;
end;
$$;
create or replace function public.start_organization_support_conversation(target_organization_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare personal_id uuid; support_id uuid;
begin
 if not public.is_organization_member(target_organization_id) then raise exception '단체 채팅 권한이 없습니다.'; end if;
 -- The existing function provisions the official support business when necessary.
 personal_id:=public.start_support_conversation();
 select business_id into support_id from public.conversations where id=personal_id;
 return public.start_organization_business_conversation(target_organization_id,support_id);
end;
$$;
revoke all on function public.start_organization_business_conversation(uuid,uuid,uuid),public.start_organization_support_conversation(uuid) from public;
grant execute on function public.start_organization_business_conversation(uuid,uuid,uuid),public.start_organization_support_conversation(uuid) to authenticated;

create or replace function public.send_chat_message(target_conversation_id uuid,message_body text)
returns uuid language plpgsql security definer set search_path='' as $$
declare person public.profiles%rowtype; convo public.conversations%rowtype; result_id uuid; actual_role text;
begin
 if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 메시지를 보낼 권한이 없습니다.'; end if;
 if nullif(btrim(message_body),'') is null or length(btrim(message_body))>4000 then raise exception '메시지는 1~4000자로 입력해주세요.'; end if;
 select * into person from public.profiles where id=auth.uid();
 select * into convo from public.conversations where id=target_conversation_id;
 actual_role:=case when public.is_admin() then 'admin' when public.owns_business(convo.business_id) then 'partner' else 'user' end;
 insert into public.messages(conversation_id,sender_id,sender_role,sender_name,body)
 values(convo.id,auth.uid(),actual_role,coalesce(nullif(person.full_name,''),'담당자'),btrim(message_body)) returning id into result_id;
 update public.conversations set last_message_at=now() where id=convo.id;
 return result_id;
end;
$$;
revoke all on function public.send_chat_message(uuid,text) from public;
grant execute on function public.send_chat_message(uuid,text) to authenticated;

create or replace function public.set_chat_presence(target_conversation_id uuid,is_active boolean default true)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 접근할 권한이 없습니다.'; end if;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,active_until,updated_at)
 values(target_conversation_id,auth.uid(),case when is_active then now()+interval '75 seconds' else now() end,now())
 on conflict(conversation_id,recipient_user_id) do update set active_until=excluded.active_until,updated_at=now();
end;
$$;
create or replace function public.mark_conversation_read(target_conversation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare convo public.conversations%rowtype; representative uuid; business_side boolean;
begin
 if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화를 확인할 권한이 없습니다.'; end if;
 select * into convo from public.conversations where id=target_conversation_id;
 business_side:=public.owns_business(convo.business_id) or public.is_admin();
 if convo.organization_id is null then
 update public.messages set read_at=now() where conversation_id=convo.id and sender_id<>auth.uid() and read_at is null;
 else
 update public.messages set read_at=now() where conversation_id=convo.id and read_at is null
 and (case when business_side then sender_role='user' else sender_role in ('partner','admin') end);
 end if;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,active_until,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,auth.uid(),now()+interval '75 seconds',now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set active_until=excluded.active_until,last_read_at=now(),last_notified_message_id=null,updated_at=now();
 if convo.organization_id is not null and not business_side then
 select representative_id into representative from public.organizations where id=convo.organization_id;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,representative,now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set last_read_at=now(),last_notified_message_id=null,updated_at=now();
 end if;
end;
$$;
revoke all on function public.set_chat_presence(uuid,boolean),public.mark_conversation_read(uuid) from public;
grant execute on function public.set_chat_presence(uuid,boolean),public.mark_conversation_read(uuid) to authenticated;

create or replace function public.enqueue_chat_message_notifications()
returns trigger language plpgsql security definer set search_path='' as $$
declare convo public.conversations%rowtype; business public.businesses%rowtype; recipient public.profiles%rowtype;
 state public.chat_notification_state%rowtype; recipient_id uuid; recipient_role text; recipient_name text;
 phone text; template text; button text; link text; related text; payload jsonb; viewing boolean;
begin
 select * into convo from public.conversations where id=new.conversation_id;
 select * into business from public.businesses where id=convo.business_id;
 if convo.id is null or business.id is null then return new; end if;
 related:=case when convo.reservation_id is not null then '예약 '||left(convo.reservation_id::text,8) else business.business_name end;
 if new.sender_role='user' then
 recipient_id:=business.owner_id; recipient_role:='owner'; template:='OWNER_CHAT_RECEIVED_V1'; button:='문의 확인';
 select * into recipient from public.profiles where id=recipient_id and status='approved';
 recipient_name:=coalesce(nullif(recipient.full_name,''),business.representative_name,'사장님');
 phone:=coalesce(nullif(recipient.phone,''),business.phone);
 link:=public.notification_owner_url('/?open=chat&conversationId='||convo.id::text);
 payload:=jsonb_build_object('사장님명',recipient_name,'고객명',coalesce(nullif(new.sender_name,''),convo.customer_name,'이용자'),'관련건',related);
 else
 if not exists(select 1 from public.messages where conversation_id=convo.id and sender_role='user') then return new; end if;
 recipient_id:=convo.customer_id;
 if convo.organization_id is not null then
 select representative_id into recipient_id from public.organizations where id=convo.organization_id;
 if not public.is_organization_member(convo.organization_id,recipient_id) then return new; end if;
 end if;
 recipient_role:='user'; template:='USER_CHAT_RECEIVED_V1'; button:='답변 확인';
 select * into recipient from public.profiles where id=recipient_id and status='approved';
 recipient_name:=coalesce(nullif(recipient.full_name,''),convo.customer_name,'이용자'); phone:=recipient.phone;
 link:=public.notification_user_url('/?route=chat&conversationId='||convo.id::text||case when convo.organization_id is not null then '&organizationId='||convo.organization_id::text else '' end);
 payload:=jsonb_build_object('고객명',coalesce((select name from public.organizations where id=convo.organization_id),recipient_name),'상대명',business.business_name,'관련건',related);
 end if;
 if recipient.id is null or nullif(trim(coalesce(phone,'')),'') is null then return new; end if;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,updated_at)
 values(convo.id,recipient_id,now()) on conflict do nothing;
 select * into state from public.chat_notification_state where conversation_id=convo.id and recipient_user_id=recipient_id for update;
 viewing:=coalesce(state.active_until>now(),false);
 if recipient_role='user' and convo.organization_id is not null then
 viewing:=viewing or exists(select 1 from public.chat_notification_state s
 where s.conversation_id=convo.id and s.active_until>now() and public.is_organization_member(convo.organization_id,s.recipient_user_id));
 end if;
 if viewing then
 update public.messages set read_at=coalesce(read_at,now()) where conversation_id=convo.id and read_at is null
 and (case when recipient_role='owner' then sender_role='user' else sender_role in ('partner','admin') end);
 update public.chat_notification_state set last_read_at=now(),last_notified_message_id=null,updated_at=now()
 where conversation_id=convo.id and recipient_user_id=recipient_id;
 return new;
 end if;
 if state.last_notified_message_id is not null then return new; end if;
 perform public.enqueue_notification(
 target_event_key:='chat_received',target_template_key:=template,target_recipient_role:=recipient_role,
 target_recipient_user_id:=recipient_id,target_recipient_name:=recipient_name,target_recipient_phone:=phone,
 target_payload:=payload,target_button_links:=jsonb_build_object(button,link),
 target_dedupe_key:='chat:'||convo.id::text||':'||recipient_id::text||':'||new.id::text);
 update public.chat_notification_state set last_notified_message_id=new.id,updated_at=now() where conversation_id=convo.id and recipient_user_id=recipient_id;
 return new;
end;
$$;

create or replace function public.cancel_removed_organization_chat_alerts()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='active' and (new.status<>'active' or (old.role='representative' and new.role<>'representative')) then
 update public.notification_outbox o set status='cancelled',last_error='단체 담당자 권한 변경',updated_at=now()
 from public.conversations c where c.organization_id=new.organization_id and o.event_key='chat_received'
 and o.recipient_role='user' and o.recipient_user_id=new.user_id and o.status='queued' and split_part(o.dedupe_key,':',2)=c.id::text;
 update public.chat_notification_state s set active_until=now(),last_notified_message_id=null,updated_at=now()
 from public.conversations c where c.organization_id=new.organization_id and s.conversation_id=c.id and s.recipient_user_id=new.user_id
 and not exists(select 1 from public.businesses b where b.id=c.business_id and b.owner_id=new.user_id);
 end if;
 return new;
end;
$$;
drop trigger if exists cancel_removed_organization_chat_alerts on public.organization_members;
create trigger cancel_removed_organization_chat_alerts after update of status,role on public.organization_members for each row execute function public.cancel_removed_organization_chat_alerts();
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
  target_reservation public.reservations%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Login is required.';
  end if;

  select * into customer_profile
  from public.profiles
  where id = auth.uid() and role = 'user' and status = 'approved';

  if customer_profile.id is null then
    raise exception 'Only approved user accounts can start chats.';
  end if;

  if not exists (
    select 1 from public.businesses
    where id = target_business_id and approval_status = 'approved'
  ) then
    raise exception 'Business is not available.';
  end if;

  if target_reservation_id is not null then
    select * into target_reservation
    from public.reservations
    where id = target_reservation_id;

    if target_reservation.id is null
      or target_reservation.organization_id is not null
      or target_reservation.customer_id is distinct from auth.uid()
      or target_reservation.business_id is distinct from target_business_id
    then
      raise exception 'Reservation does not belong to this chat.';
    end if;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(auth.uid()::text || ':' || target_business_id::text, 0)
  );

  select id into result_id
  from public.conversations
  where business_id = target_business_id and customer_id = auth.uid() and organization_id is null
  order by created_at
  limit 1;

  if result_id is null then
    insert into public.conversations (
      business_id, customer_id, reservation_id, customer_name, group_name
    ) values (
      target_business_id,
      auth.uid(),
      target_reservation_id,
      coalesce(nullif(customer_profile.full_name, ''), nullif(customer_profile.email, ''), 'User'),
      nullif(customer_profile.organization, '')
    )
    returning id into result_id;
  elsif target_reservation_id is not null then
    update public.conversations
    set reservation_id = coalesce(reservation_id, target_reservation_id)
    where id = result_id;
  end if;

  return result_id;
end;
$$;
create or replace function public.start_support_conversation()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  support_owner uuid;
  support_business uuid;
  support_conversation uuid;
  caller_name text;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;

  select p.id into support_owner from public.profiles p where p.role = 'admin' and p.status = 'approved' order by p.created_at limit 1;
  if support_owner is null then raise exception '운영팀 계정이 준비되지 않았습니다.'; end if;

  select b.id into support_business from public.businesses b where b.business_type = 'support' and b.is_internal = true limit 1;
  if support_business is null then
    insert into public.businesses (
      owner_id, business_type, business_name, representative_name, phone,
      address, description, region, approval_status, is_internal
    ) values (
      support_owner, 'support', '모티프 운영팀', '모티프 운영팀', '010-3357-2537',
      '서울특별시 중구 소공로 46 A-1102', '서비스 이용 문의와 운영 지원을 위한 공식 채팅입니다.',
      '전국', 'approved', true
    ) returning id into support_business;
  end if;

  select coalesce(p.full_name, p.email, '회원') into caller_name from public.profiles p where p.id = auth.uid();
  select c.id into support_conversation from public.conversations c
  where c.business_id = support_business and c.customer_id = auth.uid() and c.organization_id is null limit 1;

  if support_conversation is null then
    insert into public.conversations (business_id, customer_id, customer_name, group_name)
    values (support_business, auth.uid(), coalesce(caller_name, '회원'), '운영 문의')
    returning id into support_conversation;
  end if;
  return support_conversation;
end;
$$;

create or replace function public.start_partner_transaction_conversation(target_kind text,target_transaction_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare tx jsonb; bid uuid; cid uuid; oid uuid; rid uuid; result_id uuid; group_label text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;
 if target_kind='stay' then
 select to_jsonb(r) into tx from public.reservations r where id=target_transaction_id;
 rid:=target_transaction_id;
 elsif target_kind='market' then
 select to_jsonb(r) into tx from public.market_orders r where id=target_transaction_id;
 else raise exception '거래 종류를 확인해주세요.';
 end if;
 bid:=(tx->>'business_id')::uuid; cid:=(tx->>'customer_id')::uuid; oid:=(tx->>'organization_id')::uuid;
 if tx is null or not (public.owns_business(bid) or public.is_admin()) then raise exception '해당 업장의 거래만 확인할 수 있습니다.'; end if;
 if oid is null then
 if not exists(select 1 from public.profiles where id=cid and status='approved') then raise exception '현재 연락 가능한 이용자 계정이 없습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(cid::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and customer_id=cid and organization_id is null order by created_at limit 1;
 group_label:=tx->>'group_name';
 else
 select name into group_label from public.organizations where id=oid;
 perform pg_advisory_xact_lock(hashtextextended(oid::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and organization_id=oid;
 end if;
 if result_id is null then
 insert into public.conversations(business_id,customer_id,organization_id,reservation_id,customer_name,group_name)
 values(bid,cid,oid,rid,coalesce(tx->>'customer_name','이용자'),group_label) returning id into result_id;
 elsif rid is not null then
 update public.conversations set reservation_id=coalesce(reservation_id,rid) where id=result_id;
 end if;
 return result_id;
end;
$$;
revoke all on function public.start_partner_transaction_conversation(text,uuid) from public;
grant execute on function public.start_partner_transaction_conversation(text,uuid) to authenticated;


create or replace function public.start_partner_pending_conversation(target_order_id text)
returns uuid language plpgsql security definer set search_path='' as $$
declare intent public.payment_intents%rowtype; bid uuid; result_id uuid; group_label text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;
 select * into intent from public.payment_intents where order_id=target_order_id;
 bid:=(intent.draft->>'business_id')::uuid;
 if intent.id is null or not (public.owns_business(bid) or public.is_admin()) then raise exception '해당 업장의 결제 내역만 확인할 수 있습니다.'; end if;
 if intent.transaction_id is not null then return public.start_partner_transaction_conversation(intent.kind,intent.transaction_id); end if;
 if intent.status not in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit') then raise exception '종료된 결제 준비 내역입니다.'; end if;
 if intent.organization_id is null then
 if not exists(select 1 from public.profiles where id=intent.customer_id and status='approved') then raise exception '현재 연락 가능한 이용자 계정이 없습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(intent.customer_id::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and customer_id=intent.customer_id and organization_id is null order by created_at limit 1;
 group_label:=intent.draft->>'group_name';
 else
 select name into group_label from public.organizations where id=intent.organization_id;
 perform pg_advisory_xact_lock(hashtextextended(intent.organization_id::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and organization_id=intent.organization_id;
 end if;
 if result_id is null then
 insert into public.conversations(business_id,customer_id,organization_id,customer_name,group_name)
 values(bid,intent.customer_id,intent.organization_id,coalesce(intent.draft->>'customer_name','이용자'),group_label) returning id into result_id;
 end if;
 return result_id;
end;
$$;
revoke all on function public.start_partner_pending_conversation(text) from public;
grant execute on function public.start_partner_pending_conversation(text) to authenticated;

commit;
