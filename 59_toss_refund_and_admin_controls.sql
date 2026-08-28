-- Unified Toss refund ledger and safe admin controls.

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
    refund_reason=nullif(trim(refund_reason),''),
    refund_response=provider_response,
    refund_requested_at=coalesce(refund_requested_at,now()),
    refunded_at=case when refund_state='refunded' then now() else refunded_at end,
    provider_status=case when refund_percent>=100 and refund_state='refunded' then 'CANCELED' when refund_state='refunded' then 'PARTIAL_CANCELED' else provider_status end
  where id=intent.id;

  if points_refund_amount>0 and refund_state='refunded'
     and not exists(select 1 from public.point_ledger where user_id=intent.customer_id and source_type='payment_refund_'||target_transaction_kind and source_id=target_transaction_id and entry_type='refund') then
    update public.point_accounts set balance=balance+points_refund_amount,lifetime_used=greatest(lifetime_used-points_refund_amount,0),updated_at=now()
    where user_id=intent.customer_id returning balance into current_balance;
    insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id)
    values(intent.customer_id,points_refund_amount,current_balance,'refund','결제 취소 포인트 복구','payment_refund_'||target_transaction_kind,target_transaction_id);
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
      refund_reason=nullif(trim(refund_reason),''),
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
      refund_reason=nullif(trim(refund_reason),''),
      refund_response=provider_response,
      refund_requested_at=coalesce(refund_requested_at,now()),
      refunded_at=case when refund_state='refunded' then now() else refunded_at end,
      payment_status=case when refund_state='refunded' then 'refunded' when refund_state='processing' then 'refund_processing' else 'refund_failed' end
    where id=target_transaction_id;
  end if;
  perform public.sync_partner_settlements();
end;
$$;
revoke all on function public.record_toss_refund(text,uuid,integer,integer,integer,text,text,jsonb,text) from public;
grant execute on function public.record_toss_refund(text,uuid,integer,integer,integer,text,text,jsonb,text) to service_role;

-- Partial cancellation fees remain payable to the partner. A full refund cancels settlement.
create or replace function public.sync_partner_settlements()
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer:=0; changed integer; stay_rate numeric; market_rate numeric;
begin
  stay_rate:=coalesce((select (setting_value->>'stay_rate')::numeric from public.platform_settings where setting_key='commission'),0.035);
  market_rate:=coalesce((select (setting_value->>'market_rate')::numeric from public.platform_settings where setting_key='commission'),0.035);

  with stay_source as (
    select r.id,r.business_id,
      coalesce(r.original_amount,r.base_accommodation_amount,r.total_amount)::integer as original_gross,
      coalesce(r.customer_paid_amount,r.total_amount)::integer as original_paid,
      coalesce(b.commission_rate_override,stay_rate) as applied_rate,
      case when r.status='cancelled' and r.refund_status='refunded'
        then greatest(100-coalesce(r.cancellation_refund_percent,100),0)
        else 100 end as retained_percent
    from public.reservations r join public.businesses b on b.id=r.business_id
    where r.status in ('confirmed','completed')
       or (r.status='cancelled' and r.refund_status='refunded' and coalesce(r.cancellation_refund_percent,100)<100)
  ), stay_amounts as (
    select *,floor(original_gross*retained_percent/100.0)::integer as effective_gross,
      floor(original_paid*retained_percent/100.0)::integer as effective_paid
    from stay_source
  )
  insert into public.partner_settlements(
    business_id,transaction_kind,transaction_id,gross_amount,customer_paid_amount,
    platform_discount_amount,commission_rate,commission_amount,payout_amount
  )
  select business_id,'stay',id,effective_gross,effective_paid,
    greatest(effective_gross-effective_paid,0),applied_rate,
    floor(effective_gross*applied_rate)::integer,
    effective_gross-floor(effective_gross*applied_rate)::integer
  from stay_amounts
  on conflict(transaction_kind,transaction_id) do update set
    business_id=excluded.business_id,gross_amount=excluded.gross_amount,
    customer_paid_amount=excluded.customer_paid_amount,
    platform_discount_amount=excluded.platform_discount_amount,
    commission_rate=excluded.commission_rate,commission_amount=excluded.commission_amount,
    payout_amount=excluded.payout_amount,
    status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics changed=row_count; affected:=affected+changed;

  insert into public.partner_settlements(
    business_id,transaction_kind,transaction_id,gross_amount,customer_paid_amount,
    platform_discount_amount,commission_rate,commission_amount,payout_amount
  )
  select o.business_id,'market',o.id,coalesce(o.original_amount,o.total_amount),
    coalesce(o.customer_paid_amount,o.total_amount),
    coalesce(o.points_used,0)+coalesce(o.coupon_discount,0),
    coalesce(b.commission_rate_override,market_rate),
    floor(coalesce(o.original_amount,o.total_amount)*coalesce(b.commission_rate_override,market_rate))::integer,
    coalesce(o.original_amount,o.total_amount)-floor(coalesce(o.original_amount,o.total_amount)*coalesce(b.commission_rate_override,market_rate))::integer
  from public.market_orders o join public.businesses b on b.id=o.business_id
  where o.status in ('confirmed','completed')
  on conflict(transaction_kind,transaction_id) do update set
    business_id=excluded.business_id,gross_amount=excluded.gross_amount,
    customer_paid_amount=excluded.customer_paid_amount,
    platform_discount_amount=excluded.platform_discount_amount,
    commission_rate=excluded.commission_rate,commission_amount=excluded.commission_amount,
    payout_amount=excluded.payout_amount,
    status=case when public.partner_settlements.status='cancelled' then 'pending' else public.partner_settlements.status end;
  get diagnostics changed=row_count; affected:=affected+changed;

  update public.partner_settlements s set status='cancelled'
  where s.status='pending' and (
    (s.transaction_kind='stay' and not exists(
      select 1 from public.reservations r where r.id=s.transaction_id and (
        r.status in ('confirmed','completed')
        or (r.status='cancelled' and r.refund_status='refunded' and coalesce(r.cancellation_refund_percent,100)<100)
      )
    ))
    or (s.transaction_kind='market' and not exists(
      select 1 from public.market_orders o where o.id=s.transaction_id and o.status in ('confirmed','completed')
    ))
    or s.transaction_kind='extra_charge'
  );
  return affected;
end;
$$;

create or replace function public.admin_update_business_commerce(
  target_business_id uuid,
  commission_rate numeric default null,
  featured boolean default null,
  target_display_order integer default null,
  target_discovery_weight integer default null
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
  update public.businesses set
    commission_rate_override=commission_rate,
    is_featured=coalesce(featured,is_featured),
    display_order=coalesce(target_display_order,display_order),
    discovery_weight=coalesce(target_discovery_weight,discovery_weight),
    updated_at=now()
  where id=target_business_id;
  if not found then raise exception '업장을 찾을 수 없습니다.'; end if;
  insert into public.admin_audit_logs(admin_id,action,target_type,target_id,after_data)
  values(auth.uid(),'business_commerce_update','business',target_business_id::text,jsonb_build_object(
    'commission_rate',commission_rate,'featured',featured,'display_order',target_display_order,'discovery_weight',target_discovery_weight
  ));
end;
$$;
revoke all on function public.admin_update_business_commerce(uuid,numeric,boolean,integer,integer) from public;
grant execute on function public.admin_update_business_commerce(uuid,numeric,boolean,integer,integer) to authenticated;

comment on function public.record_toss_refund(text,uuid,integer,integer,integer,text,text,jsonb,text)
is 'Records Toss cash refund and restores the proportional moTF points in one database transaction';
