begin;

alter table public.businesses alter column refund_policy set default '[]'::jsonb;

-- Freeze the previous stored policy for booked intents that predate the versioned checkout.
update public.payment_intents p
set draft = jsonb_set(p.draft,'{stay_refund_policy_snapshot}',b.refund_policy)
from public.reservations r join public.businesses b on b.id = r.business_id
where r.id = p.transaction_id and p.kind = 'stay'
  and jsonb_typeof(p.draft) = 'object'
  and not (p.draft ? 'stay_refund_policy_version' or p.draft ? 'stay_refund_policy_snapshot');

-- Only the six confirmed launch listings get this schedule; keep all custom schedules.
update public.businesses
set refund_policy = '[{"days_before":30,"refund_percent":100},{"days_before":15,"refund_percent":50},{"days_before":0,"refund_percent":0}]'::jsonb
where business_type = 'stay' and approval_status = 'approved'
  and id in (
    'c79db39c-6e0a-4c0c-9217-321ef8eddd33', -- MZ 펜션
    '7390b68e-d374-4eb4-8e9d-d15034f827dc', -- 별찌 펜션
    '9b7194ab-6d5c-47e2-8a5e-0cd075b17107', -- 소란캠프
    '4cdc2170-e9d9-4694-9ed8-40f9c96dcfeb', -- 다큐하우스 펜션 (keep its existing custom policy)
    '3a2e8088-7853-49f0-976e-12255fb3f937', -- 다온다 펜션
    '50e5c710-3310-4eaa-8f09-9f7c768ff066'  -- 모짜르트 샬레
  )
  and (refund_policy = '[]'::jsonb or refund_policy = '[
    {"days_before":14,"refund_percent":100,"label":"이용 14일 전까지"},
    {"days_before":7,"refund_percent":50,"label":"이용 7일 전까지"},
    {"days_before":3,"refund_percent":20,"label":"이용 3일 전까지"},
    {"days_before":0,"refund_percent":0,"label":"이후 및 당일"}
  ]'::jsonb);

-- The exact old column default is not evidence of a policy set by a business.
update public.businesses set refund_policy = '[]'::jsonb
where business_type = 'stay' and refund_policy = '[
    {"days_before":14,"refund_percent":100,"label":"이용 14일 전까지"},
    {"days_before":7,"refund_percent":50,"label":"이용 7일 전까지"},
    {"days_before":3,"refund_percent":20,"label":"이용 3일 전까지"},
    {"days_before":0,"refund_percent":0,"label":"이후 및 당일"}
  ]'::jsonb;

update public.businesses
set description = '단체 행사에 필요한 고기, 쌈채소, 주류, 음료 등의 식자재를 합리적인 가격에 구매할 수 있는 지역 공판장입니다! 현장 수령 시 상황에 따라 숙소까지 픽업이 가능할 수 있습니다.'
where business_type = 'market' and id = 'd5513697-7341-4cc6-a16b-781caf6b902d';

create or replace function public.snapshot_stay_refund_policy()
returns trigger language plpgsql set search_path='' as $$
declare policy jsonb;
begin
  if new.kind = 'stay' then
    new.draft := coalesce(new.draft,'{}'::jsonb) - 'stay_refund_policy_version' - 'stay_refund_policy_snapshot';
    if tg_op = 'INSERT' then
      select b.refund_policy into policy from public.businesses b
      where b.id = (new.draft->>'business_id')::uuid and b.business_type = 'stay';
      new.draft := jsonb_set(new.draft,'{stay_refund_policy_snapshot}',coalesce(policy,'[]'::jsonb));
    else
      if old.draft ? 'stay_refund_policy_version' then
        new.draft := jsonb_set(new.draft,'{stay_refund_policy_version}',old.draft->'stay_refund_policy_version');
      end if;
      if old.draft ? 'stay_refund_policy_snapshot' then
        new.draft := jsonb_set(new.draft,'{stay_refund_policy_snapshot}',old.draft->'stay_refund_policy_snapshot');
      end if;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.send_chat_message(target_conversation_id uuid,message_body text)
returns uuid language plpgsql security definer set search_path='' as $$
begin
  return public.send_chat_message_before_db89(target_conversation_id,message_body);
end;
$$;

create or replace function public.send_chat_message_with_contact(target_conversation_id uuid,message_body text,contact_consent boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare person public.profiles%rowtype; bid uuid; shared_phone text;
begin
  if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 접근할 권한이 없습니다.'; end if;
  select c.business_id into bid from public.conversations c where c.id=target_conversation_id;
  if coalesce(contact_consent,false) and not public.is_admin() and not public.has_business_permission(bid,'chat') then
    select * into person from public.profiles p where p.id=auth.uid() and p.status='approved' and p.withdrawal_processed_at is null;
    shared_phone := regexp_replace(coalesce(person.phone,''),'[^0-9]','','g');
    if shared_phone !~ '^0[0-9]{8,10}$' then raise exception '계정 정보의 전화번호를 확인해주세요.'; end if;
    insert into public.conversation_contact_shares(conversation_id,user_id,contact_name,phone)
      values(target_conversation_id,auth.uid(),coalesce(nullif(person.full_name,''),'문의자'),shared_phone)
      on conflict(conversation_id,user_id) do update set contact_name=excluded.contact_name,phone=excluded.phone,
        consented_at=case when conversation_contact_shares.phone=excluded.phone then conversation_contact_shares.consented_at else now() end,last_shared_at=now();
  end if;
  return public.send_chat_message_before_db89(target_conversation_id,message_body);
end;
$$;

commit;
