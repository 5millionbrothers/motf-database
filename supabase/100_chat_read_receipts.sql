-- Read receipts are shared by the customer, partner and support interfaces.
begin;
create or replace function public.mark_conversation_read(target_conversation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare convo public.conversations%rowtype;representative uuid;business_side boolean;support_channel boolean;
begin
 if auth.uid() is null or not public.can_access_conversation(target_conversation_id) then raise exception '이 대화를 확인할 권한이 없습니다.'; end if;
 select * into convo from public.conversations where id=target_conversation_id;
 if convo.id is null then raise exception '대화를 찾지 못했습니다.'; end if;
 select b.business_type='support',b.owner_id into support_channel,representative from public.businesses b where b.id=convo.business_id;
 business_side:=public.has_business_permission(convo.business_id,'chat') or public.is_admin();

 -- A colleague reading our own side's reply is not a customer read receipt.
 update public.messages set read_at=now()
 where conversation_id=convo.id and read_at is null and sender_id<>auth.uid()
 and case when coalesce(support_channel,false) then
   case when public.is_admin() then sender_role<>'admin' else sender_role='admin' end
   when business_side then sender_role='user'
   else sender_role in ('partner','admin') end;

 insert into public.chat_notification_state(conversation_id,recipient_user_id,active_until,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,auth.uid(),now()+interval '75 seconds',now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set active_until=excluded.active_until,last_read_at=now(),last_notified_message_id=null,updated_at=now();

 if convo.organization_id is not null and not business_side then
  select representative_id into representative from public.organizations where id=convo.organization_id;
  if representative is not null then
   insert into public.chat_notification_state(conversation_id,recipient_user_id,last_read_at,last_notified_message_id,updated_at)
   values(convo.id,representative,now(),null,now())
   on conflict(conversation_id,recipient_user_id) do update set last_read_at=now(),last_notified_message_id=null,updated_at=now();
  end if;
 end if;
 if business_side and not coalesce(support_channel,false) and representative is not null then
  insert into public.chat_notification_state(conversation_id,recipient_user_id,last_read_at,last_notified_message_id,updated_at)
  values(convo.id,representative,now(),null,now())
  on conflict(conversation_id,recipient_user_id) do update set last_read_at=now(),last_notified_message_id=null,updated_at=now();
 end if;
end;
$$;
revoke all on function public.mark_conversation_read(uuid) from public,anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
