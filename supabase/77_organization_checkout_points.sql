-- Organization checkout retains the personal payer UUID, and routes points/refunds to the organization wallet.
begin;
alter table public.payment_intents add column if not exists organization_id uuid references public.organizations(id);
alter table public.point_holds add column if not exists organization_id uuid references public.organizations(id);
alter table public.reservations add column if not exists organization_id uuid references public.organizations(id);
alter table public.reservations add column if not exists booking_contact_user_id uuid references public.profiles(id);
alter table public.market_orders add column if not exists organization_id uuid references public.organizations(id);
alter table public.market_orders add column if not exists booking_contact_user_id uuid references public.profiles(id);
alter table public.organization_point_ledger add column if not exists expires_at timestamptz;
create index if not exists organization_intents on public.payment_intents(organization_id,created_at desc);
create index if not exists organization_reservations on public.reservations(organization_id,created_at desc);
create index if not exists organization_orders on public.market_orders(organization_id,created_at desc);

create or replace function public.organization_checkout_contact(target_organization_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.is_organization_member(target_organization_id) then raise exception '단체 결제 권한이 없습니다.'; end if;
 select jsonb_build_object('customer_name',p.full_name,'contact_phone',p.phone,'group_name',o.name,'contact_user_id',p.id)
 into result from public.profiles p join public.organizations o on o.id=target_organization_id where p.id=auth.uid();
 if nullif(result->>'customer_name','') is null or nullif(result->>'contact_phone','') is null then raise exception '담당자의 이름과 연락처를 먼저 입력해주세요.'; end if;
 return result;
end;
$$;
revoke all on function public.organization_checkout_contact(uuid) from public;
grant execute on function public.organization_checkout_contact(uuid) to authenticated;

create or replace function public.prepare_organization_stay_checkout(
 target_organization_id uuid,target_business_id uuid,target_offering_id uuid,customer_name text,group_name text,
 contact_phone text,event_date date,guest_count integer,request_memo text default null,check_in_date date default null,
 check_out_date date default null,requested_points integer default 0,coupon_code text default null)
returns table(order_id text,amount integer,original_amount integer,points_used integer,coupon_discount integer,order_name text,kind text)
language plpgsql security definer set search_path='' as $$
declare prepared record; benefit record; intent_id uuid; contact jsonb;
begin
 contact:=public.organization_checkout_contact(target_organization_id);
 select * into prepared from public.prepare_stay_checkout(target_business_id,target_offering_id,
 contact->>'customer_name',contact->>'group_name',contact->>'contact_phone',event_date,guest_count,request_memo,check_in_date,check_out_date,0,null);
 update public.payment_intents p set organization_id=target_organization_id,draft=draft||contact
 where p.order_id=prepared.order_id and p.customer_id=auth.uid() returning p.id into intent_id;
 select * into benefit from public.apply_checkout_benefits(intent_id,requested_points,coupon_code);
 return query select prepared.order_id,benefit.payable_amount,prepared.original_amount,benefit.applied_points,benefit.applied_coupon_discount,prepared.order_name,prepared.kind;
end;
$$;
revoke all on function public.prepare_organization_stay_checkout(uuid,uuid,uuid,text,text,text,date,integer,text,date,date,integer,text) from public;
grant execute on function public.prepare_organization_stay_checkout(uuid,uuid,uuid,text,text,text,date,integer,text,date,date,integer,text) to authenticated;

create or replace function public.prepare_organization_market_checkout(
 target_organization_id uuid,target_business_id uuid,customer_name text,contact_phone text,pickup_place text,
 pickup_time time,request_memo text,items jsonb,requested_points integer default 0,coupon_code text default null)
returns table(order_id text,amount integer,original_amount integer,points_used integer,coupon_discount integer,order_name text,kind text)
language plpgsql security definer set search_path='' as $$
declare prepared record; benefit record; intent_id uuid; contact jsonb;
begin
 contact:=public.organization_checkout_contact(target_organization_id);
 select * into prepared from public.prepare_market_checkout(target_business_id,contact->>'customer_name',
 contact->>'contact_phone',pickup_place,pickup_time,request_memo,items,0,null);
 update public.payment_intents p set organization_id=target_organization_id,draft=draft||contact
 where p.order_id=prepared.order_id and p.customer_id=auth.uid() returning p.id into intent_id;
 select * into benefit from public.apply_checkout_benefits(intent_id,requested_points,coupon_code);
 return query select prepared.order_id,benefit.payable_amount,prepared.original_amount,benefit.applied_points,benefit.applied_coupon_discount,prepared.order_name,prepared.kind;
end;
$$;
revoke all on function public.prepare_organization_market_checkout(uuid,uuid,text,text,text,time,text,jsonb,integer,text) from public;
grant execute on function public.prepare_organization_market_checkout(uuid,uuid,text,text,text,time,text,jsonb,integer,text) to authenticated;

create or replace function public.preview_organization_checkout_benefits(
 target_organization_id uuid,target_original_amount integer,target_transaction_kind text,target_business_id uuid default null,
 requested_points integer default 0,requested_coupon_code text default null)
returns table(original_amount integer,available_points integer,applied_points integer,applied_coupon_discount integer,payable_amount integer,coupon_name text)
language plpgsql stable security definer set search_path='' as $$
declare preview record; balance integer; available integer; points integer; minimum_external integer;
begin
 if not public.is_organization_member(target_organization_id) then raise exception '단체 결제 권한이 없습니다.'; end if;
 select * into preview from public.preview_checkout_benefits(target_original_amount,target_transaction_kind,target_business_id,0,requested_coupon_code);
 select a.balance into balance from public.organization_point_accounts a where a.organization_id=target_organization_id;
 select greatest(balance-coalesce(sum(h.amount),0),0) into available from public.point_holds h
 where h.organization_id=target_organization_id and h.status='held' and h.expires_at>now();
 minimum_external:=coalesce((select (setting_value->>'minimum_external_amount')::integer from public.platform_settings where setting_key='payment'),100);
 points:=least(greatest(coalesce(requested_points,0),0),available,greatest(target_original_amount-preview.applied_coupon_discount-minimum_external,0));
 return query select target_original_amount,available,points,preview.applied_coupon_discount,
 target_original_amount-preview.applied_coupon_discount-points,preview.coupon_name;
end;
$$;
revoke all on function public.preview_organization_checkout_benefits(uuid,integer,text,uuid,integer,text) from public;
grant execute on function public.preview_organization_checkout_benefits(uuid,integer,text,uuid,integer,text) to authenticated;

create or replace function public.can_read_customer_transaction(customer uuid,organization uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select case when organization is null then customer=auth.uid() else public.is_organization_member(organization) end;
$$;
revoke all on function public.can_read_customer_transaction(uuid,uuid) from public;
grant execute on function public.can_read_customer_transaction(uuid,uuid) to authenticated;
drop policy if exists reservations_read on public.reservations;
create policy reservations_read on public.reservations for select to authenticated using(
 public.can_read_customer_transaction(customer_id,organization_id) or public.owns_business(business_id) or public.is_admin());
drop policy if exists market_orders_read_participants on public.market_orders;
create policy market_orders_read_participants on public.market_orders for select to authenticated using(
 public.can_read_customer_transaction(customer_id,organization_id) or public.owns_business(business_id) or public.is_admin());
drop policy if exists market_order_items_read_participants on public.market_order_items;
create policy market_order_items_read_participants on public.market_order_items for select to authenticated using(exists(
 select 1 from public.market_orders o where o.id=order_id and
 (public.can_read_customer_transaction(o.customer_id,o.organization_id) or public.owns_business(o.business_id) or public.is_admin())));
drop policy if exists payment_intents_read_owner_or_admin on public.payment_intents;
create policy payment_intents_read_owner_or_admin on public.payment_intents for select to authenticated using(
 public.can_read_customer_transaction(customer_id,organization_id) or public.is_admin());

create or replace function public.apply_checkout_benefits(
  target_intent_id uuid,
  requested_points integer default 0,
  requested_coupon_code text default null
)
returns table(payable_amount integer, applied_points integer, applied_coupon_discount integer)
language plpgsql security definer set search_path = '' as $$
declare
  intent public.payment_intents%rowtype;
  account public.point_accounts%rowtype;
  selected_coupon public.coupons%rowtype;
  held_points integer := 0;
  available_points integer := 0;
  coupon_amount integer := 0;
  minimum_external integer := 100;
  prior_uses integer := 0;
  organization_balance integer := 0;
begin
  select * into intent from public.payment_intents where id=target_intent_id for update;
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '현재 계정으로 결제할 수 없습니다.'; end if;
  if intent.id is null or intent.customer_id<>auth.uid() or intent.status<>'prepared' then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  minimum_external := coalesce((select (setting_value->>'minimum_external_amount')::integer from public.platform_settings where setting_key='payment'),100);

  if nullif(upper(trim(requested_coupon_code)),'') is not null then
    select * into selected_coupon from public.coupons c
    where upper(c.code)=upper(trim(requested_coupon_code)) and c.is_active
      and now() between c.starts_at and c.ends_at
      and c.minimum_order_amount <= intent.original_amount
      and c.applies_to in ('all',intent.kind)
      and (c.business_id is null or c.business_id=(intent.draft->>'business_id')::uuid)
    for update;
    if selected_coupon.id is null then raise exception '사용할 수 없는 할인코드입니다.'; end if;
    select count(*) into prior_uses from public.coupon_redemptions r
    where r.coupon_id=selected_coupon.id and r.user_id=intent.customer_id and r.status in ('reserved','used');
    if prior_uses>=selected_coupon.per_user_limit then raise exception '할인코드 사용 가능 횟수를 초과했습니다.'; end if;
    if selected_coupon.total_usage_limit is not null and (
      select count(*) from public.coupon_redemptions r where r.coupon_id=selected_coupon.id and r.status in ('reserved','used')
    )>=selected_coupon.total_usage_limit then raise exception '할인코드가 모두 소진되었습니다.'; end if;
    coupon_amount := case when selected_coupon.discount_type='fixed'
      then selected_coupon.discount_value::integer
      else floor(intent.original_amount * selected_coupon.discount_value / 100)::integer end;
    coupon_amount := least(coupon_amount, coalesce(selected_coupon.maximum_discount,coupon_amount), greatest(intent.original_amount-minimum_external,0));
    if coupon_amount<=0 then raise exception '이 주문에 적용할 할인금액이 없습니다.'; end if;
    insert into public.coupon_redemptions(coupon_id,user_id,payment_intent_id,discount_amount)
    values(selected_coupon.id,intent.customer_id,intent.id,coupon_amount);
  end if;

  if intent.organization_id is null then
  insert into public.point_accounts(user_id) values(intent.customer_id) on conflict do nothing;
  select * into account from public.point_accounts where user_id=intent.customer_id for update;
  select greatest(account.balance-coalesce(sum(h.amount),0),0) into available_points
  from public.point_holds h where h.user_id=intent.customer_id and h.organization_id is null and h.status='held' and h.expires_at>now();
  held_points := least(greatest(coalesce(requested_points,0),0), available_points, greatest(intent.original_amount-coupon_amount-minimum_external,0));
  if held_points>0 then
    insert into public.point_holds(payment_intent_id,user_id,amount,expires_at)
    values(intent.id,intent.customer_id,held_points,intent.expires_at);
  end if;

  else
    if not public.is_organization_member(intent.organization_id) then raise exception '단체 결제 권한이 없습니다.'; end if;
    select balance into organization_balance from public.organization_point_accounts where organization_id=intent.organization_id for update;
    select greatest(organization_balance-coalesce(sum(h.amount),0),0) into available_points
      from public.point_holds h where h.organization_id=intent.organization_id and h.status='held' and h.expires_at>now();
    held_points:=least(greatest(coalesce(requested_points,0),0),available_points,greatest(intent.original_amount-coupon_amount-minimum_external,0));
    if held_points>0 then
      insert into public.point_holds(payment_intent_id,user_id,organization_id,amount,expires_at)
      values(intent.id,intent.customer_id,intent.organization_id,held_points,intent.expires_at);
    end if;
  end if;

  update public.payment_intents set
    amount=original_amount-coupon_amount-held_points,
    customer_paid_amount=original_amount-coupon_amount-held_points,
    points_used=held_points,
    coupon_discount=coupon_amount,
    platform_discount=coupon_amount+held_points,
    provider='toss'
  where id=intent.id;

  return query select intent.original_amount-coupon_amount-held_points, held_points, coupon_amount;
end;
$$;

create or replace function public.finalize_toss_payment_intent(
  target_customer_id uuid,
  target_order_id text,
  target_payment_key text,
  toss_payment jsonb
)
returns table(transaction_id uuid, kind text)
language plpgsql security definer set search_path = '' as $$
declare
  intent public.payment_intents%rowtype; new_id uuid; current_balance integer; response_status text; response_amount integer;
begin
  select * into intent from public.payment_intents where order_id=target_order_id for update;
  if intent.id is null or intent.customer_id<>target_customer_id then raise exception '결제 준비 내역을 찾을 수 없습니다.'; end if;
  if intent.status='confirmed' then return query select intent.transaction_id,intent.kind; return; end if;
  response_status:=toss_payment->>'status'; response_amount:=coalesce((toss_payment->>'totalAmount')::integer,-1);
  if toss_payment->>'orderId' is distinct from intent.order_id or toss_payment->>'paymentKey' is distinct from target_payment_key
     or response_amount<>intent.amount or response_status<>'DONE' then raise exception '토스 승인 정보와 결제 원장이 일치하지 않습니다.'; end if;

  if intent.kind='stay' then
    if not exists(select 1 from public.stay_availability_blocks where payment_intent_id=intent.id and source='checkout_hold' and status='active') then
      raise exception '객실 결제 보관 시간이 만료되었습니다. 다시 예약해주세요.';
    end if;
    insert into public.reservations(business_id,customer_id,offering_id,customer_name,group_name,contact_phone,event_date,end_date,guest_count,offering_name,total_amount,base_accommodation_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method,pricing_breakdown,request_memo,organization_id,booking_contact_user_id)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,(intent.draft->>'offering_id')::uuid,intent.draft->>'customer_name',intent.draft->>'group_name',intent.draft->>'contact_phone',(intent.draft->>'check_in_date')::date,(intent.draft->>'check_out_date')::date,(intent.draft->>'guest_count')::integer,intent.draft->>'offering_name',intent.original_amount,intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,toss_payment->>'method',jsonb_build_array(jsonb_build_object('label','객실 기본금','amount',intent.original_amount)),intent.draft->>'request_memo',intent.organization_id,intent.customer_id) returning id into new_id;
    update public.stay_availability_blocks set source='motf',reservation_id=new_id,note='토스 결제 승인 완료' where payment_intent_id=intent.id and status='active';
  elsif intent.kind='market' then
    insert into public.market_orders(business_id,customer_id,customer_name,contact_phone,pickup_place,pickup_time,request_memo,total_amount,original_amount,customer_paid_amount,points_used,coupon_discount,payment_method,organization_id,booking_contact_user_id)
    values((intent.draft->>'business_id')::uuid,intent.customer_id,intent.draft->>'customer_name',intent.draft->>'contact_phone',intent.draft->>'pickup_place',(intent.draft->>'pickup_time')::time,intent.draft->>'request_memo',intent.original_amount,intent.original_amount,intent.amount,intent.points_used,intent.coupon_discount,toss_payment->>'method',intent.organization_id,intent.customer_id) returning id into new_id;
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
  update public.payment_intents set status='confirmed',provider='toss',provider_status=response_status,payment_key=target_payment_key,provider_payment_id=target_payment_key,payment_method=toss_payment->>'method',payment_response=toss_payment,transaction_id=new_id,paid_at=now(),confirmed_at=now() where id=intent.id;
  return query select new_id,intent.kind;
end;
$$;

create or replace function public.record_toss_refund(
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
  total_refund:=greatest(coalesce(external_refund_amount,0),0)+greatest(coalesce(points_refund_amount,0),0);

  update public.payment_intents set
    status=case
      when refund_state='refunded' and refund_percent>=100 then 'cancelled'
      when refund_state='refunded' then 'partial_cancelled'
      else status
    end,
    refund_status=refund_state,
    refund_amount=total_refund,
    refund_reason=nullif(trim(record_toss_refund.refund_reason),''),
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
      status=coalesce(requested_transaction_status,status),
      customer_cancelled_at=case when requested_transaction_status='cancelled' then now() else customer_cancelled_at end,
      cancellation_refund_percent=refund_percent,
      refund_status=refund_state,
      refund_amount=total_refund,
      refund_reason=nullif(trim(record_toss_refund.refund_reason),''),
      refund_response=provider_response,
      refund_requested_at=coalesce(refund_requested_at,now()),
      refunded_at=case when refund_state='refunded' then now() else refunded_at end,
      payment_status=case when refund_state='refunded' then 'refunded' when refund_state='processing' then 'refund_processing' else 'refund_failed' end
    where id=target_transaction_id;
    if requested_transaction_status in ('cancelled','rejected') then
      update public.stay_availability_blocks set status='cancelled',note=coalesce(note,'')||' / Toss refund'
      where reservation_id=target_transaction_id and status='active';
    end if;
  else
    update public.market_orders set
      status=coalesce(requested_transaction_status,status),
      refund_status=refund_state,
      refund_amount=total_refund,
      refund_reason=nullif(trim(record_toss_refund.refund_reason),''),
      refund_response=provider_response,
      refund_requested_at=coalesce(refund_requested_at,now()),
      refunded_at=case when refund_state='refunded' then now() else refunded_at end,
      payment_status=case when refund_state='refunded' then 'refunded' when refund_state='processing' then 'refund_processing' else 'refund_failed' end
    where id=target_transaction_id;
  end if;
  perform public.sync_partner_settlements();
end;
$$;

create or replace function public.grant_completion_cashback()
returns trigger language plpgsql security definer set search_path = '' as $$
declare campaign public.point_campaigns%rowtype; gross integer; reward integer; current_balance integer; source_kind text;
begin
  if new.status<>'completed' or (tg_op='UPDATE' and old.status='completed') then return new; end if;
  source_kind:=case when tg_table_name='reservations' then 'stay' else 'market' end;
  gross:=coalesce(new.original_amount,new.total_amount);
  select * into campaign from public.point_campaigns c where c.is_active and c.campaign_kind='cashback'
    and c.transaction_kind in ('all',source_kind) and now() between c.starts_at and c.ends_at and gross>=c.minimum_amount
    order by c.priority,c.created_at limit 1;
  if campaign.id is null then return new; end if;
  reward:=campaign.fixed_points+floor(gross*campaign.reward_rate)::integer;
  reward:=least(reward,coalesce(campaign.max_points,reward));
  if reward<=0 then return new; end if;
  if new.organization_id is null then
  if exists(select 1 from public.point_ledger where user_id=new.customer_id and source_type='cashback_'||source_kind and source_id=new.id and entry_type='earn') then return new; end if;
  insert into public.point_accounts(user_id) values(new.customer_id) on conflict do nothing;
  update public.point_accounts set balance=balance+reward,lifetime_earned=lifetime_earned+reward,updated_at=now()
  where user_id=new.customer_id returning balance into current_balance;
  insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id,expires_at)
  values(new.customer_id,reward,current_balance,'earn',campaign.name,'cashback_'||source_kind,new.id,now()+interval '1 year');
  else
    if exists(select 1 from public.organization_point_ledger where organization_id=new.organization_id and source_type='cashback_'||source_kind and source_id=new.id and entry_type='earn') then return new; end if;
    update public.organization_point_accounts set balance=balance+reward,lifetime_earned=lifetime_earned+reward,updated_at=now()
      where organization_id=new.organization_id returning balance into current_balance;
    insert into public.organization_point_ledger(organization_id,actor_id,amount,balance_after,entry_type,reason,source_type,source_id,expires_at)
    values(new.organization_id,new.customer_id,reward,current_balance,'earn',campaign.name,'cashback_'||source_kind,new.id,now()+interval '1 year');
  end if;
  return new;
end;
$$;
revoke all on function public.apply_checkout_benefits(uuid,integer,text) from public;
grant execute on function public.apply_checkout_benefits(uuid,integer,text) to authenticated;
revoke all on function public.finalize_toss_payment_intent(uuid,text,text,jsonb) from public;
grant execute on function public.finalize_toss_payment_intent(uuid,text,text,jsonb) to service_role;
revoke all on function public.record_toss_refund(text,uuid,integer,integer,integer,text,text,jsonb,text) from public;
grant execute on function public.record_toss_refund(text,uuid,integer,integer,integer,text,text,jsonb,text) to service_role;
create or replace function public.preview_checkout_benefits(
  target_original_amount integer,
  target_transaction_kind text,
  target_business_id uuid default null,
  requested_points integer default 0,
  requested_coupon_code text default null
)
returns table(
  original_amount integer,
  available_points integer,
  applied_points integer,
  applied_coupon_discount integer,
  payable_amount integer,
  coupon_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  account_balance integer := 0;
  held_points integer := 0;
  usable_points integer := 0;
  point_amount integer := 0;
  coupon_amount integer := 0;
  minimum_external integer := 100;
  selected_coupon public.coupons%rowtype;
  prior_uses integer := 0;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'approved'
  ) then
    raise exception '현재 결제할 수 없는 계정입니다.';
  end if;
  if target_original_amount is null or target_original_amount <= 0 then raise exception '주문 금액을 확인해주세요.'; end if;
  if target_transaction_kind not in ('stay', 'market') then raise exception '결제 종류를 확인해주세요.'; end if;

  minimum_external := coalesce((
    select (setting_value ->> 'minimum_external_amount')::integer
    from public.platform_settings where setting_key = 'payment'
  ), 100);

  select coalesce((
    select a.balance
    from public.point_accounts a
    where a.user_id = auth.uid()
  ), 0) into account_balance;
  select coalesce(sum(h.amount), 0) into held_points
  from public.point_holds h
  where h.user_id = auth.uid() and h.organization_id is null and h.status = 'held' and h.expires_at > now();
  usable_points := greatest(account_balance - held_points, 0);

  if nullif(upper(trim(requested_coupon_code)), '') is not null then
    select * into selected_coupon
    from public.coupons c
    where upper(c.code) = upper(trim(requested_coupon_code))
      and c.is_active
      and now() between c.starts_at and c.ends_at
      and c.minimum_order_amount <= target_original_amount
      and c.applies_to in ('all', target_transaction_kind)
      and (c.business_id is null or c.business_id = target_business_id);
    if selected_coupon.id is null then raise exception '사용할 수 없는 할인코드입니다.'; end if;

    select count(*) into prior_uses
    from public.coupon_redemptions r
    where r.coupon_id = selected_coupon.id
      and r.user_id = auth.uid()
      and r.status in ('reserved', 'used');
    if prior_uses >= selected_coupon.per_user_limit then raise exception '할인코드 사용 가능 횟수를 초과했습니다.'; end if;
    if selected_coupon.total_usage_limit is not null and (
      select count(*) from public.coupon_redemptions r
      where r.coupon_id = selected_coupon.id and r.status in ('reserved', 'used')
    ) >= selected_coupon.total_usage_limit then
      raise exception '할인코드가 모두 소진되었습니다.';
    end if;

    coupon_amount := case when selected_coupon.discount_type = 'fixed'
      then selected_coupon.discount_value::integer
      else floor(target_original_amount * selected_coupon.discount_value / 100)::integer end;
    coupon_amount := least(
      coupon_amount,
      coalesce(selected_coupon.maximum_discount, coupon_amount),
      greatest(target_original_amount - minimum_external, 0)
    );
    if coupon_amount <= 0 then raise exception '이 주문에 적용할 할인금액이 없습니다.'; end if;
  end if;

  point_amount := least(
    greatest(coalesce(requested_points, 0), 0),
    usable_points,
    greatest(target_original_amount - coupon_amount - minimum_external, 0)
  );

  return query select
    target_original_amount,
    usable_points,
    point_amount,
    coupon_amount,
    target_original_amount - coupon_amount - point_amount,
    selected_coupon.name;
end;
$$;

create or replace function public.freeze_transaction_account()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.customer_id is distinct from old.customer_id then raise exception '결제 담당자는 변경할 수 없습니다.'; end if;
 if new.organization_id is distinct from old.organization_id then
  if tg_table_name<>'payment_intents' or old.organization_id is not null or old.status<>'prepared'
   or old.points_used<>0 or auth.uid() is distinct from old.customer_id
   or not public.is_organization_member(new.organization_id) then raise exception '거래 소속은 변경할 수 없습니다.'; end if;
 end if;
 if tg_table_name in ('reservations','market_orders') then
  if new.booking_contact_user_id is distinct from old.booking_contact_user_id then raise exception '예약 당시 담당자는 변경할 수 없습니다.'; end if;
 end if;
 return new;
end;
$$;
drop trigger if exists freeze_transaction_account on public.payment_intents;
create trigger freeze_transaction_account before update on public.payment_intents for each row execute function public.freeze_transaction_account();
drop trigger if exists freeze_transaction_account on public.reservations;
create trigger freeze_transaction_account before update on public.reservations for each row execute function public.freeze_transaction_account();
drop trigger if exists freeze_transaction_account on public.market_orders;
create trigger freeze_transaction_account before update on public.market_orders for each row execute function public.freeze_transaction_account();
drop policy if exists organization_reservation_insert_guard on public.reservations;
create policy organization_reservation_insert_guard on public.reservations as restrictive for insert to authenticated
 with check(organization_id is null or public.is_organization_member(organization_id));

revoke all on function public.preview_checkout_benefits(integer,text,uuid,integer,text) from public;
grant execute on function public.preview_checkout_benefits(integer,text,uuid,integer,text) to authenticated;
commit;
