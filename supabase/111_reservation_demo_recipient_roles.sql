begin;
create or replace function public.reservation_demo_live_flow()
returns trigger language plpgsql security definer set search_path='' as $$
declare business public.businesses%rowtype;owner_profile public.profiles%rowtype;creator public.profiles%rowtype;
 convo uuid;payload jsonb;owner_phone text;owner_name text;owner_link text;admin_link text;template text;event text;
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
 select * into creator from public.profiles where id=new.created_by;
 owner_phone:=public.business_notification_phone(business.id);
 owner_name:=coalesce(nullif(business.representative_name,''),nullif(owner_profile.full_name,''),'사장님');
 owner_link:=public.notification_owner_url('/?open=orders&demoId='||new.id::text||'&businessId='||new.business_id::text);
 admin_link:=public.notification_owner_url('/?open=demo&demoId='||new.id::text);
 payload:=jsonb_build_object('business_id',business.id,'demo_id',new.id,'시연',true,'고객명','[시연] '||new.customer_name,'사장님명',owner_name,
  '숙소명','[결제 없는 시연] '||business.business_name,'객실명',new.offering_name,
  '예약일정',public.notification_date_range(new.check_in,new.check_out),'예약번호',new.id::text,
  '인원',new.guest_count::text,'금액',public.notification_money(0),'환불금액',public.notification_money(0),
  '취소사유','[시연] '||coalesce(new.reject_reason,'실제 결제·환불 없음'));
 if tg_op='INSERT' then
  if owner_phone is null then raise exception '사장님 수신번호를 운영자 알림 수신번호 화면에서 먼저 확인해주세요: %',business.business_name; end if;
  if not public.is_notification_mobile(new.contact_phone) then raise exception '시연 이용자 수신번호를 확인해주세요.'; end if;
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
  template:=case when new.status='confirmed' then 'USER_RESERVATION_CONFIRMED_V1' else 'USER_RESERVATION_CANCELLED_V1' end;event:=new.status;
 end if;
 perform public.enqueue_notification('demo_reservation_'||event,template,'user',new.created_by,'[시연] '||new.customer_name,new.contact_phone,payload,
   jsonb_build_object('예약내역 보기',admin_link),'reservation_demo:'||new.id::text||':'||event||':user');
 if tg_op='UPDATE' and public.is_notification_mobile(creator.phone) then
  perform public.enqueue_notification('demo_reservation_status','ADMIN_RESERVATION_STATUS_V1','admin',new.created_by,'시연 운영자',creator.phone,
    payload||jsonb_build_object('예약상태','[시연] '||case when new.status='confirmed' then '승인' else '거절' end),
    jsonb_build_object('관리자 확인',admin_link),'reservation_demo:'||new.id::text||':'||event||':admin');
 end if;
 return new;
end;
$$;
revoke all on function public.reservation_demo_live_flow() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
