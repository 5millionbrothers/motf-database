begin;
-- An HTTP timeout is not proof of non-delivery. Never automatically replay it.
create or replace function public.mark_notification_delivery_unknown(
  target_outbox_id uuid, target_request_payload jsonb, target_error_message text
) returns void language plpgsql security definer set search_path='' as $$
declare item public.notification_outbox%rowtype;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception '서버 권한이 필요합니다.' using errcode='42501'; end if;
  select * into item from public.notification_outbox where id=target_outbox_id for update;
  if item.id is null or item.status<>'processing' then return; end if;
  update public.notification_outbox set status='failed',provider='aligo',locked_at=null,
    failed_at=now(),last_error='[수신 결과 확인 필요 · 자동 재발송 안 함] '||coalesce(target_error_message,''),updated_at=now()
    where id=item.id;
  insert into public.notification_logs(outbox_id,template_key,recipient_role,recipient_phone,action,status,provider,request_payload,response_payload,error_message)
    values(item.id,item.template_key,item.recipient_role,item.recipient_phone,'delivery_review','failed','aligo',
      coalesce(target_request_payload,'{}'),jsonb_build_object('deliveryUnknown',true),target_error_message);
end;
$$;
revoke all on function public.mark_notification_delivery_unknown(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.mark_notification_delivery_unknown(uuid,jsonb,text) to service_role;

create or replace function public.request_notification_dispatch_followup()
returns void language plpgsql security definer set search_path='' as $$
declare dispatch_secret text; dispatch_url text; request_id bigint;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception '서버 권한이 필요합니다.' using errcode='42501'; end if;
  if not exists(select 1 from public.notification_outbox where status='queued' and next_attempt_at<=now()) then return; end if;
  dispatch_secret:=public.notification_dispatch_secret('motf_notification_dispatch_secret');
  dispatch_url:=coalesce(nullif(public.notification_dispatch_secret('motf_notification_dispatch_url'),''),'https://motf.co.kr/api/notifications-dispatch');
  if nullif(trim(dispatch_secret),'') is null then raise exception '알림 발송 시크릿을 확인해주세요.'; end if;
  select net.http_post(url:=dispatch_url,
    body:=jsonb_build_object('limit',4,'source','notification_outbox_trigger'),
    headers:=jsonb_build_object('Content-Type','application/json','x-notification-secret',dispatch_secret),
    timeout_milliseconds:=65000) into request_id;
  insert into public.notification_dispatch_pings(request_id,dispatch_url,source)
    values(request_id,dispatch_url,'dispatch_followup');
end;
$$;
revoke all on function public.request_notification_dispatch_followup() from public,anon,authenticated;
grant execute on function public.request_notification_dispatch_followup() to service_role;

create or replace function public.reservation_demo_delivery_audit(target_demo_ids uuid[])
returns table(demo_id uuid,recipient_role text,template_key text,status text,attempt_count integer,
  last_error text,provider_message_id text,actual_last4 text,test_mode text)
language sql stable security definer set search_path='' as $$
  select d.id,n.recipient_role,n.template_key,n.status,n.attempt_count,n.last_error,n.provider_message_id,
    right(coalesce(l.request_payload->>'recipientPhone',n.recipient_phone),4),l.request_payload->>'testMode'
  from public.reservation_demos d join public.notification_outbox n on n.payload->>'demo_id'=d.id::text
  left join lateral(select request_payload from public.notification_logs where outbox_id=n.id order by created_at desc,id desc limit 1) l on true
  where d.id=any(target_demo_ids) and cardinality(target_demo_ids)<=100
    and (public.is_admin() or public.has_business_permission(d.business_id,'reservations'))
  order by n.created_at;
$$;
revoke all on function public.reservation_demo_delivery_audit(uuid[]) from public,anon;
grant execute on function public.reservation_demo_delivery_audit(uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
