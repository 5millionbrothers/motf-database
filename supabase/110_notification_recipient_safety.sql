-- No global pause, no phone backfill, and no replay of sent notifications.
begin;
create table if not exists public.business_notification_contacts (
 business_id uuid primary key references public.businesses(id) on delete cascade,
 owner_id uuid not null references public.profiles(id) on delete cascade,
 phone text not null,
 business_phone_snapshot text,
 account_phone_snapshot text,
 confirmed_by uuid not null,
 confirmed_at timestamptz not null default now()
);
alter table public.business_notification_contacts enable row level security;
revoke all on public.business_notification_contacts from public,anon,authenticated;

create table if not exists public.contact_change_audit (
 id uuid primary key default gen_random_uuid(),
 subject_type text not null, subject_id uuid not null, field_name text not null,
 previous_phone text, new_phone text, changed_by uuid, changed_at timestamptz not null default now()
);
alter table public.contact_change_audit enable row level security;
revoke all on public.contact_change_audit from public,anon,authenticated;

create or replace function public.normalize_notification_phone(value text)
returns text language sql immutable set search_path='' as $$
 select regexp_replace(coalesce(value,''),'[^0-9]','','g');
$$;
create or replace function public.is_notification_mobile(value text)
returns boolean language sql immutable set search_path='' as $$
 select public.normalize_notification_phone(value) ~ '^(010[0-9]{8}|01[16789][0-9]{7,8})$'
 and public.normalize_notification_phone(value) !~ '^010([0-9])\1{7}$'
 and public.normalize_notification_phone(value) <> '01012121212';
$$;

create or replace function public.audit_contact_change()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.phone is distinct from old.phone then
  insert into public.contact_change_audit(subject_type,subject_id,field_name,previous_phone,new_phone,changed_by)
  values(tg_table_name,new.id,'phone',old.phone,new.phone,auth.uid());
 end if;
 return new;
end;
$$;
revoke all on function public.audit_contact_change() from public,anon,authenticated;
drop trigger if exists audit_business_contact_change on public.businesses;
create trigger audit_business_contact_change after update of phone on public.businesses
 for each row execute function public.audit_contact_change();
drop trigger if exists audit_profile_contact_change on public.profiles;
create trigger audit_profile_contact_change after update of phone on public.profiles
 for each row execute function public.audit_contact_change();

create or replace function public.business_notification_phone(target_business_id uuid)
returns text language sql stable security definer set search_path='' as $$
 select case
  when c.owner_id=b.owner_id and c.business_phone_snapshot is not distinct from b.phone
   and c.account_phone_snapshot is not distinct from p.phone and public.is_notification_mobile(c.phone) then c.phone
  when public.is_notification_mobile(p.phone)
   and public.normalize_notification_phone(p.phone)=public.normalize_notification_phone(b.phone)
   and not exists(select 1 from public.profiles a where a.role='admin'
    and public.normalize_notification_phone(a.phone)=public.normalize_notification_phone(p.phone))
   then public.normalize_notification_phone(p.phone)
  else null end
 from public.businesses b join public.profiles p on p.id=b.owner_id
 left join public.business_notification_contacts c on c.business_id=b.id
 where b.id=target_business_id and p.status='approved';
$$;
revoke all on function public.business_notification_phone(uuid) from public,anon,authenticated;
grant execute on function public.business_notification_phone(uuid) to service_role;

create or replace function public.own_business_notification_phone(target_business_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.is_admin() or public.has_business_permission(target_business_id,'listing'),false)
 then raise exception '해당 업장 관리 권한이 없습니다.'; end if;
 return public.business_notification_phone(target_business_id);
end;
$$;
revoke all on function public.own_business_notification_phone(uuid) from public,anon;
grant execute on function public.own_business_notification_phone(uuid) to authenticated;

create or replace function public.list_business_notification_contacts()
returns table(business_id uuid,business_name text,business_phone text,account_phone text,
 account_name text,notification_phone text,confirmation_required boolean)
language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.is_admin(),false) then raise exception '운영자 권한이 필요합니다.'; end if;
 return query select b.id,b.business_name,b.phone,p.phone,p.full_name,public.business_notification_phone(b.id),
  public.business_notification_phone(b.id) is null
 from public.businesses b left join public.profiles p on p.id=b.owner_id
 where b.business_type in ('stay','market') order by b.business_name;
end;
$$;
revoke all on function public.list_business_notification_contacts() from public,anon;
grant execute on function public.list_business_notification_contacts() to authenticated;

create or replace function public.confirm_business_notification_contact(target_business_id uuid,target_phone text)
returns void language plpgsql security definer set search_path='' as $$
declare b public.businesses%rowtype;p public.profiles%rowtype;previous text;phone text;
begin
 if not coalesce(public.is_admin(),false) then raise exception '운영자 권한이 필요합니다.'; end if;
 phone:=public.normalize_notification_phone(target_phone);
 if not public.is_notification_mobile(phone) then raise exception '실제 알림을 받을 휴대폰 번호를 확인해주세요.'; end if;
 select * into b from public.businesses where id=target_business_id for update;
 select * into p from public.profiles where id=b.owner_id;
 if b.id is null or p.id is null then raise exception '업장과 대표 계정을 확인해주세요.'; end if;
 select c.phone into previous from public.business_notification_contacts c where c.business_id=b.id;
 insert into public.business_notification_contacts(business_id,owner_id,phone,business_phone_snapshot,account_phone_snapshot,confirmed_by,confirmed_at)
 values(b.id,b.owner_id,phone,b.phone,p.phone,auth.uid(),now())
 on conflict(business_id) do update set owner_id=excluded.owner_id,phone=excluded.phone,
  business_phone_snapshot=excluded.business_phone_snapshot,account_phone_snapshot=excluded.account_phone_snapshot,
  confirmed_by=excluded.confirmed_by,confirmed_at=excluded.confirmed_at;
 insert into public.contact_change_audit(subject_type,subject_id,field_name,previous_phone,new_phone,changed_by)
 values('businesses',b.id,'notification_phone',previous,phone,auth.uid());
end;
$$;
revoke all on function public.confirm_business_notification_contact(uuid,text) from public,anon;
grant execute on function public.confirm_business_notification_contact(uuid,text) to authenticated;

create or replace function public.update_partner_contact_phone(target_phone text,expected_profile_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare normalized_phone text:=public.normalize_notification_phone(target_phone);
begin
 if auth.uid() is distinct from expected_profile_id then raise exception '로그인 계정이 변경되었습니다. 다시 확인해주세요.'; end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role in ('partner','admin') and status='approved')
 then raise exception '사장님 계정으로 로그인해주세요.'; end if;
 if not public.is_notification_mobile(normalized_phone) then raise exception '연락받을 휴대폰 번호를 확인해주세요.'; end if;
 update public.profiles set phone=normalized_phone,updated_at=now() where id=auth.uid();
 return normalized_phone;
end;
$$;
revoke all on function public.update_partner_contact_phone(text,uuid) from public,anon;
grant execute on function public.update_partner_contact_phone(text,uuid) to authenticated;

create or replace function public.notification_delivery_route(target_outbox_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare n public.notification_outbox%rowtype;b public.businesses%rowtype;p public.profiles%rowtype;
 phone text;bid uuid;cid uuid;demo_id uuid;context_id text;matches integer;route_source text:='outbox';
begin
 if coalesce(auth.role(),'')<>'service_role' and not coalesce(public.is_admin(),false)
 then raise exception '알림 발송 서버 권한이 필요합니다.'; end if;
 select * into n from public.notification_outbox where id=target_outbox_id;
 if n.id is null then raise exception '알림 대기열을 찾지 못했습니다.'; end if;
 if exists(select 1 from public.reservation_demos d where d.id::text=n.payload->>'demo_id'
   and (d.archived_at is not null or d.expires_at<=now())) then raise exception '종료된 시연의 알림은 발송하지 않습니다.'; end if;
 phone:=public.normalize_notification_phone(n.recipient_phone);
 if n.recipient_role='owner' then
  select * into p from public.profiles where id=n.recipient_user_id;
  begin
   bid:=nullif(n.payload->>'business_id','')::uuid;
   if bid is null then
    select (substring(v from 'businessId=([0-9a-fA-F-]{36})'))::uuid into bid
    from jsonb_each_text(n.button_links) as links(k,v) where v like '%businessId=%' limit 1;
   end if;
   if bid is null then
    select (substring(v from 'conversationId=([0-9a-fA-F-]{36})'))::uuid into cid
    from jsonb_each_text(n.button_links) as links(k,v) where v like '%conversationId=%' limit 1;
    select business_id into bid from public.conversations where id=cid;
   end if;
   if bid is null then
    context_id:=n.payload->>'예약번호';
    if context_id is null then select substring(v from 'reservationId=([0-9a-fA-F-]{36})') into context_id
     from jsonb_each_text(n.button_links) as links(k,v) where v like '%reservationId=%' limit 1; end if;
    select business_id into bid from public.reservations where id::text=context_id;
   end if;
   if bid is null then
    context_id:=n.payload->>'주문번호';
    if context_id is null then select substring(v from 'orderId=([0-9a-fA-F-]{36})') into context_id
     from jsonb_each_text(n.button_links) as links(k,v) where v like '%orderId=%' limit 1; end if;
    select business_id into bid from public.market_orders where id::text=context_id;
   end if;
   if bid is null then
    select substring(v from 'settlementId=([0-9a-fA-F-]{36})') into context_id
     from jsonb_each_text(n.button_links) as links(k,v) where v like '%settlementId=%' limit 1;
    select business_id into bid from public.partner_settlements where id::text=context_id;
   end if;
   if bid is null then
    select substring(v from 'offeringId=([0-9a-fA-F-]{36})') into context_id
     from jsonb_each_text(n.button_links) as links(k,v) where v like '%offeringId=%' limit 1;
    select business_id into bid from public.offerings where id::text=context_id;
   end if;
   if bid is null and n.event_key='owner_admin_notice' then
    bid:=split_part(n.dedupe_key,':',2)::uuid;
   end if;
  exception when invalid_text_representation then raise exception '알림의 업장 연결 정보를 확인해주세요.'; end;
  if bid is null then
   select count(*) into matches from public.businesses where owner_id=n.recipient_user_id and business_type in ('stay','market');
   if matches=1 then select id into bid from public.businesses where owner_id=n.recipient_user_id and business_type in ('stay','market'); end if;
  end if;
  if bid is null and p.role='admin' and n.template_key='OWNER_CHAT_RECEIVED_V1' then
   phone:=public.normalize_notification_phone(p.phone);route_source:='support_admin_account';
  else
   select * into b from public.businesses where id=bid and owner_id=n.recipient_user_id;
   if b.id is null then raise exception '사장님 알림의 대상 업장을 확인해주세요.'; end if;
   phone:=public.business_notification_phone(b.id);route_source:='business_contact';
   if phone is null then raise exception '연락처가 다르거나 임시번호·운영자 공용번호입니다. 운영자 알림 수신번호 화면에서 확인해주세요: %',b.business_name; end if;
  end if;
 elsif n.recipient_role='user' then
  -- In a demo the creator plays the customer, but the explicit demo phone is the destination.
  select d.contact_phone,d.id into phone,demo_id from public.reservation_demos d
   where d.id::text=n.payload->>'demo_id' or (d.conversation_id is not null and n.button_links::text like '%'||d.conversation_id::text||'%') limit 1;
  if demo_id is not null and exists(select 1 from public.reservation_demos d where d.id=demo_id
   and (d.archived_at is not null or d.expires_at<=now())) then raise exception '종료된 시연의 알림은 발송하지 않습니다.'; end if;
  if demo_id is null then phone:=public.normalize_notification_phone(n.recipient_phone);
  else route_source:='demo_customer'; end if;
 end if;
 if not public.is_notification_mobile(phone) then raise exception '알림 수신 휴대폰 번호를 확인해주세요. 안심번호·임시번호로는 발송하지 않습니다.'; end if;
 return jsonb_build_object('recipient_phone',public.normalize_notification_phone(phone),'recipient_role',n.recipient_role,
  'recipient_user_id',n.recipient_user_id,'routing_source',route_source,'queued_phone',n.recipient_phone);
end;
$$;
revoke all on function public.notification_delivery_route(uuid) from public,anon,authenticated;
grant execute on function public.notification_delivery_route(uuid) to service_role;
notify pgrst,'reload schema';
commit;
