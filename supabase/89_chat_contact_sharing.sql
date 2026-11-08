-- Contact disclosure is explicit and scoped to the conversation's business, not the public catalog.
begin;
grant select(phone) on public.businesses to anon,authenticated;
create table if not exists public.conversation_contact_shares (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  contact_name text not null,
  phone text not null,
  consented_at timestamptz not null default now(),
  last_shared_at timestamptz not null default now(),
  primary key(conversation_id,user_id)
);
alter table public.conversation_contact_shares enable row level security;
revoke all on public.conversation_contact_shares from public,anon,authenticated;
grant select on public.conversation_contact_shares to authenticated;
grant all on public.conversation_contact_shares to service_role;
drop policy if exists conversation_contacts_read on public.conversation_contact_shares;
create policy conversation_contacts_read on public.conversation_contact_shares for select to authenticated using(
  public.can_access_conversation(conversation_id) and (user_id=auth.uid() or public.is_admin() or exists(
    select 1 from public.conversations c where c.id=conversation_id and public.has_business_permission(c.business_id,'chat')
  ))
);

do $$ begin
  if to_regprocedure('public.send_chat_message_before_db89(uuid,text)') is null then
    alter function public.send_chat_message(uuid,text) rename to send_chat_message_before_db89;
  end if;
end $$;
revoke all on function public.send_chat_message_before_db89(uuid,text) from public,anon,authenticated,service_role;
create or replace function public.send_chat_message(target_conversation_id uuid,message_body text)
returns uuid language plpgsql security definer set search_path='' as $$
declare bid uuid; shared_phone text;
begin
  if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 접근할 권한이 없습니다.'; end if;
  select c.business_id into bid from public.conversations c where c.id=target_conversation_id;
  if not public.is_admin() and not public.has_business_permission(bid,'chat') then
    select regexp_replace(coalesce(p.phone,''),'[^0-9]','','g') into shared_phone from public.profiles p where p.id=auth.uid();
    if shared_phone is null or shared_phone !~ '^0[0-9]{8,10}$' or not exists(
      select 1 from public.conversation_contact_shares s where s.conversation_id=target_conversation_id
      and s.user_id=auth.uid() and s.phone=shared_phone) then
      raise exception '전화번호 공유 안내를 확인한 뒤 새 채팅 화면에서 전송해주세요.';
    end if;
  end if;
  return public.send_chat_message_before_db89(target_conversation_id,message_body);
end;
$$;
create or replace function public.send_chat_message_with_contact(target_conversation_id uuid,message_body text,contact_consent boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare person public.profiles%rowtype; bid uuid; shared_phone text;
begin
  if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 접근할 권한이 없습니다.'; end if;
  select c.business_id into bid from public.conversations c where c.id=target_conversation_id;
  if not public.is_admin() and not public.has_business_permission(bid,'chat') then
    if not coalesce(contact_consent,false) then raise exception '문의 전화번호 공유에 동의해주세요.'; end if;
    select * into person from public.profiles p where p.id=auth.uid() and p.status='approved' and p.withdrawal_processed_at is null;
    shared_phone:=regexp_replace(coalesce(person.phone,''),'[^0-9]','','g');
    if shared_phone !~ '^0[0-9]{8,10}$' then raise exception '계정 정보에 연락 가능한 전화번호를 먼저 등록해주세요.'; end if;
    insert into public.conversation_contact_shares(conversation_id,user_id,contact_name,phone)
      values(target_conversation_id,auth.uid(),coalesce(nullif(person.full_name,''),'문의자'),shared_phone)
      on conflict(conversation_id,user_id) do update set contact_name=excluded.contact_name,phone=excluded.phone,
        consented_at=case when conversation_contact_shares.phone=excluded.phone then conversation_contact_shares.consented_at else now() end,last_shared_at=now();
  end if;
  return public.send_chat_message(target_conversation_id,message_body);
end;
$$;
revoke all on function public.send_chat_message(uuid,text),public.send_chat_message_with_contact(uuid,text,boolean) from public,anon;
grant execute on function public.send_chat_message(uuid,text),public.send_chat_message_with_contact(uuid,text,boolean) to authenticated;
commit;
