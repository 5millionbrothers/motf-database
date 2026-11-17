-- Reuse the live outbox and chat stack, but keep simulated transactions out of finance.
begin;
alter table public.reservation_demos add column if not exists live_notifications boolean not null default false;
alter table public.reservation_demos alter column live_notifications set default true;
alter table public.reservation_demos add column if not exists conversation_id uuid references public.conversations(id);

create or replace function public.reservation_demo_live_flow()
returns trigger language plpgsql security definer set search_path='' as $$
declare business public.businesses%rowtype;owner_profile public.profiles%rowtype;convo uuid;payload jsonb;links jsonb;
  owner_phone text;owner_name text;owner_link text;admin_link text;template text;event text;
begin
 if tg_op='UPDATE' then
  if new.archived_at is not null and old.archived_at is null then
   update public.notification_outbox n set status='cancelled',last_error='예약 시연 종료',updated_at=now()
    where (n.payload->>'demo_id'=new.id::text or (new.conversation_id is not null and n.button_links::text like '%'||new.conversation_id::text||'%')) and n.status='queued';
   update public.conversations set launch_archived_at=now() where id=new.conversation_id;
   return new;
  end if;
  if new.status is not distinct from old.status then return new; end if;
 end if;
 if not new.live_notifications or new.archived_at is not null then return new; end if;
 select * into business from public.businesses where id=new.business_id;
 select * into owner_profile from public.profiles where id=business.owner_id;
 owner_phone:=regexp_replace(coalesce(nullif(trim(owner_profile.phone),''),business.phone,''),'[^0-9]','','g');
 owner_name:=coalesce(nullif(owner_profile.full_name,''),business.representative_name,'사장님');
 owner_link:=public.notification_owner_url('/?open=orders&demoId='||new.id::text||'&businessId='||new.business_id::text);
 admin_link:=public.notification_owner_url('/?open=demo&demoId='||new.id::text);
 payload:=jsonb_build_object('demo_id',new.id,'시연',true,'고객명','[시연] '||new.customer_name,'사장님명',owner_name,
  '숙소명','[결제 없는 시연] '||business.business_name,'객실명',new.offering_name,
  '예약일정',public.notification_date_range(new.check_in,new.check_out),'예약번호',new.id::text,
  '인원',new.guest_count::text,'금액',public.notification_money(0),'환불금액',public.notification_money(0),
  '취소사유','[시연] '||coalesce(new.reject_reason,'실제 결제·환불 없음'));
 if tg_op='INSERT' then
  if owner_phone !~ '^0[0-9]{8,10}$' then raise exception '사장님 수신 전화번호를 확인한 뒤 시연해주세요: %',business.business_name; end if;
  insert into public.conversations(business_id,customer_id,customer_name,group_name,customer_opened_at)
   values(new.business_id,new.created_by,'[시연] '||new.customer_name,'모티프 예약 시연',now()) returning id into convo;
  update public.reservation_demos set conversation_id=convo where id=new.id;
  insert into public.conversation_contact_shares(conversation_id,user_id,contact_name,phone)
   values(convo,new.created_by,'[시연] '||new.customer_name,new.contact_phone);
  perform public.enqueue_notification('demo_reservation_requested','OWNER_RESERVATION_REQUEST_V1','owner',business.owner_id,owner_name,owner_phone,payload,
    jsonb_build_object('예약 확인',owner_link,'수락 처리',owner_link||'&demoAction=confirmed','취소 처리',owner_link||'&demoAction=rejected'),
    'reservation_demo:'||new.id::text||':requested:owner');
  template:='USER_RESERVATION_REQUESTED_V1';event:='requested';
 else
  template:=case when new.status='confirmed' then 'USER_RESERVATION_CONFIRMED_V1' else 'USER_RESERVATION_CANCELLED_V1' end;
  event:=new.status;
 end if;
 perform public.enqueue_notification('demo_reservation_'||event,template,'user',new.created_by,'[시연] '||new.customer_name,new.contact_phone,payload,
   jsonb_build_object('예약내역 보기',admin_link),'reservation_demo:'||new.id::text||':'||event||':user');
 if tg_op='UPDATE' then
  perform public.enqueue_notification('demo_reservation_status','ADMIN_RESERVATION_STATUS_V1','admin',new.created_by,'시연 운영자',new.contact_phone,
    payload||jsonb_build_object('예약상태','[시연] '||case when new.status='confirmed' then '승인' else '거절' end),
    jsonb_build_object('관리자 확인',admin_link),'reservation_demo:'||new.id::text||':'||event||':admin');
 end if;
 return new;
end;
$$;
revoke all on function public.reservation_demo_live_flow() from public,anon,authenticated;
drop trigger if exists reservation_demo_live_events on public.reservation_demos;
create trigger reservation_demo_live_events after insert or update of status,archived_at on public.reservation_demos
 for each row execute function public.reservation_demo_live_flow();

create or replace function public.send_reservation_demo_inquiry(target_demo_id uuid,message_body text)
returns uuid language plpgsql security definer set search_path='' as $$
declare demo public.reservation_demos%rowtype;result uuid;
begin
 if not coalesce(public.is_admin(),false) then raise exception '운영자만 시연 문의를 보낼 수 있습니다.'; end if;
 select * into demo from public.reservation_demos where id=target_demo_id and archived_at is null and expires_at>now() for update;
 if demo.conversation_id is null then raise exception '이전 시연입니다. 새 테스트 예약을 만든 뒤 문의해주세요.'; end if;
 if length(trim(coalesce(message_body,''))) not between 1 and 3900 then raise exception '문의 내용을 입력해주세요.'; end if;
 insert into public.messages(conversation_id,sender_id,sender_role,sender_name,body)
 values(demo.conversation_id,auth.uid(),'user','[시연] '||demo.customer_name,'[예약 시연] '||trim(message_body)) returning id into result;
 update public.conversations set last_message_at=now() where id=demo.conversation_id;
 return result;
end;
$$;
revoke all on function public.send_reservation_demo_inquiry(uuid,text) from public,anon;
grant execute on function public.send_reservation_demo_inquiry(uuid,text) to authenticated;

create or replace function public.reservation_demo_deliveries(target_demo_ids uuid[])
returns table(demo_id uuid,recipient_role text,template_key text,status text,attempt_count integer,last_error text,provider_message_id text)
language sql stable security definer set search_path='' as $$
 select d.id,n.recipient_role,n.template_key,n.status,n.attempt_count,n.last_error,n.provider_message_id
 from public.reservation_demos d join public.notification_outbox n on n.payload->>'demo_id'=d.id::text
 where d.id=any(target_demo_ids) and cardinality(target_demo_ids)<=100
 and (public.is_admin() or public.has_business_permission(d.business_id,'reservations')) order by n.created_at;
$$;
revoke all on function public.reservation_demo_deliveries(uuid[]) from public,anon;
grant execute on function public.reservation_demo_deliveries(uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
