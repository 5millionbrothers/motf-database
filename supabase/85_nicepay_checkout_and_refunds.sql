begin;

alter table public.payment_intents add column if not exists provider_merchant_id text;
create table if not exists public.nicepay_checkout_sessions (
  payment_intent_id uuid primary key references public.payment_intents(id) on delete restrict,
  nonce_hash text not null check (nonce_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.nicepay_checkout_sessions enable row level security;
revoke all on public.nicepay_checkout_sessions from public,anon,authenticated;
grant select,insert,update on public.nicepay_checkout_sessions to service_role;

create or replace function public.bind_nicepay_checkout(
  target_order_id text, target_customer_id uuid, target_mid text, target_method text, target_nonce_hash text
)
returns void language plpgsql security definer set search_path='' as $$
declare intent public.payment_intents%rowtype;
begin
  select * into intent from public.payment_intents where order_id=target_order_id for update;
  if intent.id is null or intent.customer_id<>target_customer_id then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  if intent.status not in ('prepared','ready') or intent.expires_at<=now() then raise exception '결제 준비 시간이 만료되었거나 이미 처리 중입니다.'; end if;
  if target_mid !~ '^[A-Za-z0-9]{10}$' or target_method not in ('CARD','BANK','VBANK','CELLPHONE') then raise exception '결제 설정을 확인해주세요.'; end if;
  if exists(select 1 from public.payment_provider_operations where payment_intent_id=intent.id and state not in ('failed','cancelled')) then raise exception '결제 상태를 먼저 확인해주세요.'; end if;
  update public.payment_intents set provider='nicepay',provider_merchant_id=target_mid,payment_method=target_method,
    expires_at=now()+interval '15 minutes' where id=intent.id;
  update public.point_holds set expires_at=now()+interval '15 minutes' where payment_intent_id=intent.id and status='held';
  update public.market_inventory_holds set expires_at=now()+interval '15 minutes' where payment_intent_id=intent.id and status='held';
  insert into public.nicepay_checkout_sessions(payment_intent_id,nonce_hash,expires_at)
  values(intent.id,target_nonce_hash,now()+interval '15 minutes')
  on conflict(payment_intent_id) do update set nonce_hash=excluded.nonce_hash,expires_at=excluded.expires_at;
end;
$$;
revoke all on function public.bind_nicepay_checkout(text,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.bind_nicepay_checkout(text,uuid,text,text,text) to service_role;

create or replace function public.record_nicepay_virtual_account(target_order_id text, target_payment_key text, target_account jsonb, target_expires_at timestamptz)
returns void language plpgsql security definer set search_path='' as $$
declare intent public.payment_intents%rowtype;
begin
  select * into intent from public.payment_intents where order_id=target_order_id for update;
  if intent.provider<>'nicepay' or intent.payment_key is distinct from target_payment_key or intent.payment_method<>'VBANK'
    or intent.status not in ('in_progress','virtual_account_issued') then raise exception '가상계좌 주문 정보가 일치하지 않습니다.'; end if;
  if target_expires_at<=now() or target_expires_at>now()+interval '7 days' or nullif(target_account->>'accountNumber','') is null then raise exception '가상계좌 입금 정보를 확인해주세요.'; end if;
  update public.payment_intents set status='virtual_account_issued',virtual_account=target_account,
    virtual_account_issued_at=coalesce(virtual_account_issued_at,now()),expires_at=target_expires_at where id=intent.id;
  update public.stay_availability_blocks set source='pending_payment' where payment_intent_id=intent.id and status='active';
  update public.point_holds set expires_at=target_expires_at where payment_intent_id=intent.id and status='held';
  update public.market_inventory_holds set expires_at=target_expires_at where payment_intent_id=intent.id and status='held';
end;
$$;
revoke all on function public.record_nicepay_virtual_account(text,text,jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.record_nicepay_virtual_account(text,text,jsonb,timestamptz) to service_role;

-- Generic finalization and refund functions are appended below from migration 77,
-- preserving organization wallets, inventory holds and existing order snapshots.
create or replace function public.release_expired_checkout_intents()
returns integer language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  update public.payment_intents set status='expired'
  where status in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit') and expires_at<=now();
  get diagnostics affected=row_count;
  update public.point_holds h set status='released',released_at=now()
    from public.payment_intents pi where h.payment_intent_id=pi.id and h.status='held' and pi.status in ('expired','failed','cancelled','aborted');
  update public.coupon_redemptions r set status='released'
    from public.payment_intents pi where r.payment_intent_id=pi.id and r.status='reserved' and pi.status in ('expired','failed','cancelled','aborted');
  update public.market_inventory_holds h set status='released'
    from public.payment_intents pi where h.payment_intent_id=pi.id and h.status='held' and pi.status in ('expired','failed','cancelled','aborted');
  update public.stay_availability_blocks b set status='cancelled',note=coalesce(b.note,'')||' / checkout expired'
    from public.payment_intents pi where b.payment_intent_id=pi.id and b.source in ('checkout_hold','pending_payment') and b.status='active' and pi.status in ('expired','failed','cancelled','aborted');
  return affected;
end;
$$;

-- GENERATED PROVIDER FUNCTIONS
create or replace function public.finalize_provider_payment_intent(
  target_provider text,
  target_customer_id uuid,
  target_order_id text,
  target_payment_key text,
  verified_payment jsonb
)
returns table(transaction_id uuid, kind text)
language plpgsql security definer set search_path = '' as $$
declare
  intent public.payment_intents%rowtype; new_id uuid; current_balance integer; response_status text; response_amount integer;
begin
  select * into intent from public.payment_intents where order_id=target_order_id for update;
  if intent.id is null or intent.customer_id<>target_customer_id then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  if target_provider not in ('toss','nicepay') or intent.provider is distinct from target_provider then raise exception '원결제 PG가 일치하지 않습니다.'; end if;
  if intent.status='confirmed' and intent.payment_key is distinct from target_payment_key then raise exception '원결제 거래번호가 일치하지 않습니다.'; end if;
  if intent.status='confirmed' then return query select intent.transaction_id,intent.kind; return; end if;
  if intent.status not in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit') or intent.expires_at<=now() then raise exception '결제 보관 시간이 만료되었습니다. 운영팀 확인이 필요합니다.'; end if;
  response_status:=verified_payment->>'status'; response_amount:=coalesce((verified_payment->>'amount')::integer,-1);
  if verified_payment->>'order_id' is distinct from intent.order_id or verified_payment->>'payment_key' is distinct from target_payment_key
     or response_amount<>intent.amount or response_status<>'paid' then raise exception 'PG 승인 정보와 결제 원장이 일치하지 않습니다.'; end if;

  if intent.kind='stay' then
    if not exists(select 1 from public.stay_availability_blocks where payment_intent_id=intent.id and source in ('checkout_hold','pending_payment') and status='active') then
      raise exception '객실 결제 보관 시간이 만료되었습니다. 다시 예약해주세요.';
    end if;
    insert into public.reservations(business_id,customer_id,offering_id,customer_name,group_name,contact_phone,event_date,end_date,guest_count,offering_name,total_amount,base_accommodation_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method,pricing_breakdown,request_memo,organization_id,booking_contact_user_id)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,(intent.draft->>'offering_id')::uuid,intent.draft->>'customer_name',intent.draft->>'group_name',intent.draft->>'contact_phone',(intent.draft->>'check_in_date')::date,(intent.draft->>'check_out_date')::date,(intent.draft->>'guest_count')::integer,intent.draft->>'offering_name',intent.original_amount,intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,verified_payment->>'method',jsonb_build_array(jsonb_build_object('label','객실 기본금','amount',intent.original_amount)),intent.draft->>'request_memo',intent.organization_id,intent.customer_id) returning id into new_id;
    update public.stay_availability_blocks set source='motf',reservation_id=new_id,note='PG 결제 승인 완료' where payment_intent_id=intent.id and status='active';
  elsif intent.kind='market' then
    if exists(select 1 from jsonb_to_recordset(intent.draft->'items') x(offering_id uuid,quantity integer) where not exists(select 1 from public.market_inventory_holds h where h.payment_intent_id=intent.id and h.offering_id=x.offering_id and h.quantity=x.quantity and h.status='held' and h.expires_at>now())) then raise exception '상품 재고 보관 시간이 만료되었습니다.'; end if;
    insert into public.market_orders(business_id,customer_id,customer_name,contact_phone,pickup_place,pickup_time,request_memo,total_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method,organization_id,booking_contact_user_id)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,intent.draft->>'customer_name',intent.draft->>'contact_phone',intent.draft->>'pickup_place',(intent.draft->>'pickup_time')::time,intent.draft->>'request_memo',intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,verified_payment->>'method',intent.organization_id,intent.customer_id) returning id into new_id;
    insert into public.market_order_items(order_id,offering_id,item_name,quantity,unit_price)
    select new_id,x.offering_id,x.item_name,x.quantity,x.unit_price from jsonb_to_recordset(intent.draft->'items') x(offering_id uuid,item_name text,quantity integer,unit_price integer,is_alcohol boolean);
    update public.offerings o set stock_quantity=o.stock_quantity-h.quantity,updated_at=now()
    from public.market_inventory_holds h where h.payment_intent_id=intent.id and h.offering_id=o.id and h.status='held' and o.stock_quantity is not null;
    update public.market_inventory_holds set status='consumed' where payment_intent_id=intent.id and status='held';
  else
    raise exception '신규 결제에서 지원하지 않는 거래 종류입니다.';
  end if;

  if intent.points_used>0 then
    if intent.organization_id is null then
    update public.point_accounts set balance=balance-intent.points_used,lifetime_used=lifetime_used+intent.points_used,updated_at=now()
    where user_id=intent.customer_id and balance>=intent.points_used returning balance into current_balance;
    if current_balance is null then raise exception '포인트 잔액이 변경되어 결제를 확정할 수 없습니다.'; end if;
    insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id)
    values(intent.customer_id,-intent.points_used,current_balance,'use','결제 포인트 사용',intent.kind,new_id);
    else
      update public.organization_point_accounts set balance=balance-intent.points_used,lifetime_used=lifetime_used+intent.points_used,updated_at=now()
        where organization_id=intent.organization_id and balance>=intent.points_used returning balance into current_balance;
      if current_balance is null then raise exception '단체 포인트 잔액이 변경되었습니다.'; end if;
      insert into public.organization_point_ledger(organization_id,actor_id,amount,balance_after,entry_type,reason,source_type,source_id)
      values(intent.organization_id,intent.customer_id,-intent.points_used,current_balance,'use','단체 결제 포인트 사용',intent.kind,new_id);
    end if;
    update public.point_holds set status='consumed',consumed_at=now() where payment_intent_id=intent.id;
  end if;
  update public.coupon_redemptions set status='used',used_at=now() where payment_intent_id=intent.id and status='reserved';
  update public.payment_intents set status='confirmed',provider=target_provider,provider_status=response_status,payment_key=target_payment_key,provider_payment_id=target_payment_key,payment_method=verified_payment->>'method',payment_response=verified_payment,transaction_id=new_id,paid_at=now(),confirmed_at=now() where id=intent.id;
  return query select new_id,intent.kind;
end;
$$;

create or replace function public.record_provider_refund(
  target_provider text,
  target_transaction_kind text,
  target_transaction_id uuid,
  external_refund_amount integer,
  points_refund_amount integer,
  refund_percent integer,
  refund_reason text,
  refund_state text,
  provider_response jsonb,
  requested_transaction_status text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare intent public.payment_intents%rowtype; current_balance integer; total_refund integer;
begin
  if target_transaction_kind not in ('stay','market') then raise exception '지원하지 않는 거래 종류입니다.'; end if;
  if refund_state not in ('processing','refunded','failed') then raise exception '환불 상태가 올바르지 않습니다.'; end if;
  select * into intent from public.payment_intents
  where kind=target_transaction_kind and transaction_id=target_transaction_id
    and status in ('confirmed','cancelled','partial_cancelled') for update;
  if intent.id is null then raise exception '결제 원장을 찾을 수 없습니다.'; end if;
  if target_provider not in ('nicepay','toss') or intent.provider is distinct from target_provider then raise exception '원결제 PG가 일치하지 않습니다.'; end if;
  if external_refund_amount<0 or external_refund_amount>intent.amount or refund_percent<0 or refund_percent>100 then raise exception '환불 금액을 확인해주세요.'; end if;
  total_refund:=greatest(coalesce(external_refund_amount,0),0)+greatest(coalesce(points_refund_amount,0),0);

  update public.payment_intents set
    status=case
      when refund_state='refunded' and refund_percent>=100 then 'cancelled'
      when refund_state='refunded' then 'partial_cancelled'
      else status
    end,
    refund_status=refund_state,
    refund_amount=total_refund,
    refund_reason=nullif(trim(record_provider_refund.refund_reason),''),
    refund_response=provider_response,
    refund_requested_at=coalesce(refund_requested_at,now()),
    refunded_at=case when refund_state='refunded' then now() else refunded_at end,
    provider_status=case when refund_percent>=100 and refund_state='refunded' then 'CANCELED' when refund_state='refunded' then 'PARTIAL_CANCELED' else provider_status end
  where id=intent.id;

  if points_refund_amount<0 or points_refund_amount>intent.points_used then raise exception '포인트 환불액을 확인해주세요.'; end if;
  if intent.organization_id is null then
  if points_refund_amount>0 and refund_state='refunded'
     and not exists(select 1 from public.point_ledger where user_id=intent.customer_id and source_type='payment_refund_'||target_transaction_kind and source_id=target_transaction_id and entry_type='refund') then
    update public.point_accounts set balance=balance+points_refund_amount,lifetime_used=greatest(lifetime_used-points_refund_amount,0),updated_at=now()
    where user_id=intent.customer_id returning balance into current_balance;
    insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id)
    values(intent.customer_id,points_refund_amount,current_balance,'refund','결제 취소 포인트 복구','payment_refund_'||target_transaction_kind,target_transaction_id);
  end if;

  elsif points_refund_amount>0 and refund_state='refunded' and not exists(
    select 1 from public.organization_point_ledger where organization_id=intent.organization_id and source_type='payment_refund_'||target_transaction_kind and source_id=target_transaction_id and entry_type='refund') then
    update public.organization_point_accounts set balance=balance+points_refund_amount,lifetime_used=greatest(lifetime_used-points_refund_amount,0),updated_at=now()
      where organization_id=intent.organization_id returning balance into current_balance;
    insert into public.organization_point_ledger(organization_id,actor_id,amount,balance_after,entry_type,reason,source_type,source_id)
    values(intent.organization_id,intent.customer_id,points_refund_amount,current_balance,'refund','단체 결제 취소 포인트 복구','payment_refund_'||target_transaction_kind,target_transaction_id);
  end if;

  if refund_percent>=100 and refund_state='refunded' then
    update public.coupon_redemptions set status='released' where payment_intent_id=intent.id and status='used';
  end if;

  if target_transaction_kind='stay' then
    update public.reservations set
      status=case when refund_state='refunded' then coalesce(requested_transaction_status,status) else status end,
      customer_cancelled_at=case when requested_transaction_status='cancelled' then now() else customer_cancelled_at end,
      cancellation_refund_percent=refund_percent,
      refund_status=refund_state,
      refund_amount=total_refund,
      refund_reason=nullif(trim(record_provider_refund.refund_reason),''),
      refund_response=provider_response,
      refund_requested_at=coalesce(refund_requested_at,now()),
      refunded_at=case when refund_state='refunded' then now() else refunded_at end,
      payment_status=case when refund_state='refunded' then 'refunded' when refund_state='processing' then 'refund_processing' else 'refund_failed' end
    where id=target_transaction_id;
    if refund_state='refunded' and requested_transaction_status in ('cancelled','rejected') then
      update public.stay_availability_blocks set status='cancelled',note=coalesce(note,'')||' / PG refund'
      where reservation_id=target_transaction_id and status='active';
    end if;
  else
    update public.market_orders set
      status=case when refund_state='refunded' then coalesce(requested_transaction_status,status) else status end,
      refund_status=refund_state,
      refund_amount=total_refund,
      refund_reason=nullif(trim(record_provider_refund.refund_reason),''),
      refund_response=provider_response,
      refund_requested_at=coalesce(refund_requested_at,now()),
      refunded_at=case when refund_state='refunded' then now() else refunded_at end,
      payment_status=case when refund_state='refunded' then 'refunded' when refund_state='processing' then 'refund_processing' else 'refund_failed' end
    where id=target_transaction_id;
  end if;
  perform public.sync_partner_settlements();
end;
$$;

revoke all on function public.finalize_provider_payment_intent(text,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.finalize_provider_payment_intent(text,uuid,text,text,jsonb) to service_role;
revoke all on function public.record_provider_refund(text,text,uuid,integer,integer,integer,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.record_provider_refund(text,text,uuid,integer,integer,integer,text,text,jsonb,text) to service_role;

-- Keep unresolved approvals visible without allowing partners to confirm them.
create or replace function public.list_pending_payment_intents(target_business_id uuid default null)
returns table(
  order_id text, kind text, amount integer, order_name text, status text,
  virtual_account jsonb, virtual_account_issued_at timestamptz,
  created_at timestamptz, expires_at timestamptz, draft jsonb,
  business_id uuid, business_name text
)
language plpgsql security definer set search_path = '' as $$
begin
  perform public.release_expired_pending_stay_blocks();
  if target_business_id is not null
    and not public.has_business_permission(target_business_id,'reservations')
    and not public.is_admin() then
    raise exception 'You do not have permission to read this business.';
  end if;
  return query
  select pi.order_id, pi.kind, pi.amount, pi.order_name, pi.status,
    pi.virtual_account, pi.virtual_account_issued_at, pi.created_at,
    pi.expires_at, pi.draft, b.id, b.business_name
  from public.payment_intents pi
  join public.businesses b on b.id::text=pi.draft->>'business_id'
  where (
    pi.status='virtual_account_issued'
    or (pi.provider='nicepay' and pi.payment_key is not null
      and pi.status in ('in_progress','expired'))
  )
    and (target_business_id is null or b.id=target_business_id)
    and (public.is_admin() or (
      public.has_business_permission(b.id,'reservations')
      and b.approval_status='approved'
    ))
  order by pi.created_at desc;
end;
$$;
revoke all on function public.list_pending_payment_intents(uuid) from public,anon;
grant execute on function public.list_pending_payment_intents(uuid) to authenticated;

-- Existing Toss finalization/refund functions are intentionally not replaced.
commit;
