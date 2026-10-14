-- Explicit permission guards; owns_business remains representative-only.
begin;
create or replace function public.save_business_offerings(target_business_id uuid, items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  item_id uuid;
  submitted_ids uuid[] := '{}';
  feature_values text[];
  image_values text[];
  fallback_price integer;
begin
  if not public.has_business_permission(target_business_id,'listing') and not public.is_admin() then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;

  for item in select value from jsonb_array_elements(items)
  loop
    if nullif(trim(item->>'name'), '') is null then raise exception '객실 또는 상품 이름을 입력해주세요.'; end if;
    item_id := nullif(item->>'id', '')::uuid;
    if item_id is not null and not exists (
      select 1 from public.offerings o where o.id = item_id and o.business_id = target_business_id
    ) then raise exception '수정할 수 없는 객실 또는 상품입니다.'; end if;
    item_id := coalesce(item_id, gen_random_uuid());

    select coalesce(array_agg(value), '{}') into feature_values
    from jsonb_array_elements_text(case when jsonb_typeof(item->'feature_summary') = 'array' then item->'feature_summary' else '[]'::jsonb end);
    select coalesce(array_agg(value), '{}') into image_values
    from jsonb_array_elements_text(case when jsonb_typeof(item->'image_urls') = 'array' then item->'image_urls' else '[]'::jsonb end);

    fallback_price := greatest(coalesce(
      nullif(item->>'offseason_weekday_price', '')::integer,
      nullif(item->>'price', '')::integer,
      0
    ), 0);

    insert into public.offerings (
      id, business_id, name, description, price, is_active, max_people, min_people,
      base_people, extra_person_fee, unit, category, image_url, image_urls, sort_order,
      feature_summary, amenity_details, detail_sections, origin, nutrition_info,
      is_alcohol, stock_quantity, offseason_weekday_price, offseason_weekend_price,
      shoulder_weekday_price, shoulder_weekend_price, peak_weekday_price, peak_weekend_price,
      bathroom_count, bathroom_gender_separated, bathroom_note, updated_at
    ) values (
      item_id, target_business_id, trim(item->>'name'), nullif(trim(item->>'description'), ''), fallback_price,
      coalesce(nullif(item->>'is_active', '')::boolean, true),
      nullif(item->>'max_people', '')::integer, nullif(item->>'min_people', '')::integer,
      nullif(item->>'base_people', '')::integer, nullif(item->>'extra_person_fee', '')::integer,
      nullif(trim(item->>'unit'), ''), nullif(trim(item->>'category'), ''),
      coalesce(nullif(trim(item->>'image_url'), ''), image_values[1]), image_values,
      coalesce(nullif(item->>'sort_order', '')::integer, 0), feature_values,
      case when jsonb_typeof(item->'amenity_details') = 'array' then item->'amenity_details' else '[]'::jsonb end,
      case when jsonb_typeof(item->'detail_sections') = 'object' then item->'detail_sections' else '{}'::jsonb end,
      nullif(trim(item->>'origin'), ''),
      case when jsonb_typeof(item->'nutrition_info') = 'object' then item->'nutrition_info' else '{}'::jsonb end,
      coalesce(nullif(item->>'is_alcohol', '')::boolean, false), nullif(item->>'stock_quantity', '')::integer,
      coalesce(nullif(item->>'offseason_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'offseason_weekend_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'shoulder_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'shoulder_weekend_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'peak_weekday_price', '')::integer, fallback_price),
      coalesce(nullif(item->>'peak_weekend_price', '')::integer, fallback_price),
      greatest(coalesce(nullif(item->>'bathroom_count', '')::integer, 0), 0),
      coalesce(nullif(item->>'bathroom_gender_separated', '')::boolean, false),
      nullif(trim(item->>'bathroom_note'), ''), now()
    )
    on conflict (id) do update set
      name = excluded.name, description = excluded.description, price = excluded.price,
      is_active = excluded.is_active, max_people = excluded.max_people, min_people = excluded.min_people,
      base_people = excluded.base_people, extra_person_fee = excluded.extra_person_fee,
      unit = excluded.unit, category = excluded.category, image_url = excluded.image_url,
      image_urls = excluded.image_urls, sort_order = excluded.sort_order,
      feature_summary = excluded.feature_summary, amenity_details = excluded.amenity_details,
      detail_sections = excluded.detail_sections, origin = excluded.origin,
      nutrition_info = excluded.nutrition_info, is_alcohol = excluded.is_alcohol,
      stock_quantity = excluded.stock_quantity,
      offseason_weekday_price = excluded.offseason_weekday_price,
      offseason_weekend_price = excluded.offseason_weekend_price,
      shoulder_weekday_price = excluded.shoulder_weekday_price,
      shoulder_weekend_price = excluded.shoulder_weekend_price,
      peak_weekday_price = excluded.peak_weekday_price,
      peak_weekend_price = excluded.peak_weekend_price,
      bathroom_count = excluded.bathroom_count,
      bathroom_gender_separated = excluded.bathroom_gender_separated,
      bathroom_note = excluded.bathroom_note,
      updated_at = now();
    submitted_ids := array_append(submitted_ids, item_id);
  end loop;

  update public.offerings set is_active = false, updated_at = now()
  where business_id = target_business_id and not (id = any(submitted_ids));
  perform public.refresh_business_highlights(target_business_id);
end;
$$;

create or replace function public.refresh_business_nearby_distances(target_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  station_distance integer;
  convenience_distance integer;
begin
  select * into target_business from public.businesses where id = target_business_id;
  if target_business.id is null then raise exception '업장을 찾을 수 없습니다.'; end if;
  if auth.uid() is not null
     and not public.has_business_permission(target_business_id,'listing')
     and not public.is_admin() then
    raise exception '업장 위치를 갱신할 권한이 없습니다.';
  end if;

  if target_business.latitude is null or target_business.longitude is null then
    update public.businesses
    set station_distance_m = null, convenience_distance_m = null
    where id = target_business_id;
    return;
  end if;

  select min(public.distance_meters(
    target_business.latitude::numeric,
    target_business.longitude::numeric,
    p.latitude::numeric,
    p.longitude::numeric
  )) into station_distance
  from public.location_reference_points p
  where p.reference_type = 'station'
    and p.is_active
    and (p.region is null or target_business.region is null or p.region = target_business.region);

  select min(public.distance_meters(
    target_business.latitude::numeric,
    target_business.longitude::numeric,
    p.latitude::numeric,
    p.longitude::numeric
  )) into convenience_distance
  from public.location_reference_points p
  where p.reference_type = 'convenience'
    and p.is_active
    and (p.region is null or target_business.region is null or p.region = target_business.region);

  update public.businesses
  set station_distance_m = station_distance,
      convenience_distance_m = convenience_distance,
      nearby_tags = array(
        select distinct tag
        from unnest(
          array_remove(array_remove(coalesce(nearby_tags, '{}'), 'station'), 'convenience')
          || case when station_distance is not null and station_distance <= 500 then array['station'] else '{}'::text[] end
          || case when convenience_distance is not null and convenience_distance <= 500 then array['convenience'] else '{}'::text[] end
        ) tag
      ),
      updated_at = now()
  where id = target_business_id;
end;
$$;

create or replace function public.refresh_business_highlights(target_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
 if auth.uid() is not null and not public.has_business_permission(target_business_id,'listing') and not public.is_admin() then raise exception '업장 수정 권한이 없습니다.'; end if;
  update public.businesses
  set highlight_summary = public.build_business_highlight_summary(id, highlight_keys)
  where id = target_business_id and cardinality(highlight_keys) > 0;
end;
$$;

create or replace function public.submit_business_listing_review(
  target_business_id uuid, proposed_business jsonb, proposed_offerings jsonb, requested_type text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  request_id uuid;
  target_business public.businesses%rowtype;
begin
  select * into target_business from public.businesses where id = target_business_id;
  if target_business.id is null or (not public.has_business_permission(target_business_id,'listing') and not public.is_admin()) then
    raise exception '업장 심사 요청 권한이 없습니다.';
  end if;
  if requested_type not in ('new_listing', 'listing_update') then raise exception '올바르지 않은 심사 유형입니다.'; end if;
  if jsonb_typeof(coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb)) <> 'object'
    or jsonb_typeof(coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb)) <> 'array' then
    raise exception '심사 데이터 형식이 올바르지 않습니다.';
  end if;
  if requested_type = 'listing_update' and target_business.approval_status <> 'approved' then
    raise exception '승인된 업장만 변경 심사를 요청할 수 있습니다.';
  end if;

  update public.business_listing_review_requests as review
  set request_type = requested_type,
      proposed_business = coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb),
      proposed_offerings = coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb),
      review_note = null, reviewed_by = null, reviewed_at = null, updated_at = now()
  where review.business_id = target_business_id and review.status = 'pending'
  returning review.id into request_id;
  if request_id is null then
    insert into public.business_listing_review_requests
      (business_id, requester_id, request_type, proposed_business, proposed_offerings)
    values (target_business_id, auth.uid(), requested_type,
      coalesce(submit_business_listing_review.proposed_business, '{}'::jsonb),
      coalesce(submit_business_listing_review.proposed_offerings, '[]'::jsonb))
    returning id into request_id;
  end if;
  return request_id;
end;
$$;

create or replace function public.create_stay_manual_block(
  target_offering_id uuid,
  target_check_in date,
  target_check_out date,
  block_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  new_block_id uuid;
begin
  perform public.release_expired_pending_stay_blocks();

  select * into selected_offering
  from public.offerings
  where id = target_offering_id;

  if selected_offering.id is null then
    raise exception 'Offering not found.';
  end if;
  if not public.has_business_permission(selected_offering.business_id,'availability') and not public.is_admin() then
    raise exception 'You do not have permission to block this offering.';
  end if;
  if target_check_in is null or target_check_out is null or target_check_in >= target_check_out then
    raise exception 'Invalid block date range.';
  end if;
  if not public.stay_range_is_available(target_offering_id, target_check_in, target_check_out) then
    raise exception 'This date range is already blocked.';
  end if;

  insert into public.stay_availability_blocks (
    business_id, offering_id, start_date, end_date, source, note
  ) values (
    selected_offering.business_id, selected_offering.id, target_check_in, target_check_out, 'manual', nullif(trim(block_note), '')
  ) returning id into new_block_id;

  return new_block_id;
end;
$$;

create or replace function public.set_reservation_status(
  target_reservation_id uuid,
  new_status text,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business uuid;
  target_amount integer;
  target_current_status text;
  has_confirmed_payment boolean;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Invalid reservation status.';
  end if;

  select business_id, total_amount, status
  into target_business, target_amount, target_current_status
  from public.reservations
  where id = target_reservation_id;

  if target_business is null then
    raise exception 'Reservation not found.';
  end if;

  if not public.has_business_permission(target_business,'reservations') and not public.is_admin() then
    raise exception 'You do not have permission to handle this reservation.';
  end if;

  if target_current_status in ('rejected', 'cancelled', 'completed') then
    raise exception 'Closed reservations cannot be changed.';
  end if;

  select exists (
    select 1
    from public.payment_intents
    where kind = 'stay'
      and transaction_id = target_reservation_id
      and status = 'confirmed'
      and payment_key is not null
  ) into has_confirmed_payment;

  update public.reservations
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      payment_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'refund_required'
        else payment_status
      end,
      refund_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'required'
        when new_status = 'rejected' then 'none'
        else refund_status
      end,
      refund_amount = case
        when new_status = 'rejected' and has_confirmed_payment then total_amount
        when new_status = 'rejected' then null
        else refund_amount
      end,
      refund_reason = case
        when new_status = 'rejected' and has_confirmed_payment then coalesce(nullif(reason, ''), 'Reservation rejected')
        when new_status = 'rejected' then null
        else refund_reason
      end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_reservation_id;

  if new_status in ('rejected', 'cancelled') then
    update public.stay_availability_blocks
    set status = 'cancelled',
        note = coalesce(note, '') || case when note is null or note = '' then '' else ' / ' end || 'reservation closed'
    where reservation_id = target_reservation_id
      and status = 'active';
  end if;

  if new_status = 'rejected' and has_confirmed_payment then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), 'Reservation rejected')
    where kind = 'stay'
      and transaction_id = target_reservation_id
      and status = 'confirmed';
  end if;
end;
$$;

create or replace function public.set_market_order_status(
  target_order_id uuid,
  new_status text,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business uuid;
  target_amount integer;
  target_current_status text;
  has_confirmed_payment boolean;
begin
  if new_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Invalid order status.';
  end if;

  select business_id, total_amount, status
  into target_business, target_amount, target_current_status
  from public.market_orders
  where id = target_order_id;

  if target_business is null then
    raise exception 'Order not found.';
  end if;

  if not public.has_business_permission(target_business,'reservations') and not public.is_admin() then
    raise exception 'You do not have permission to handle this order.';
  end if;

  if target_current_status in ('rejected', 'cancelled', 'completed') then
    raise exception 'Closed orders cannot be changed.';
  end if;

  select exists (
    select 1
    from public.payment_intents
    where kind = 'market'
      and transaction_id = target_order_id
      and status = 'confirmed'
      and payment_key is not null
  ) into has_confirmed_payment;

  update public.market_orders
  set status = new_status,
      reject_reason = case when new_status = 'rejected' then reason else null end,
      payment_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'refund_required'
        else payment_status
      end,
      refund_status = case
        when new_status = 'rejected' and has_confirmed_payment then 'required'
        when new_status = 'rejected' then 'none'
        else refund_status
      end,
      refund_amount = case
        when new_status = 'rejected' and has_confirmed_payment then total_amount
        when new_status = 'rejected' then null
        else refund_amount
      end,
      refund_reason = case
        when new_status = 'rejected' and has_confirmed_payment then coalesce(nullif(reason, ''), 'Order rejected')
        when new_status = 'rejected' then null
        else refund_reason
      end,
      handled_by = auth.uid(),
      handled_by_admin = public.is_admin()
  where id = target_order_id;

  if new_status = 'rejected' and has_confirmed_payment then
    update public.payment_intents
    set refund_status = 'required',
        refund_amount = target_amount,
        refund_reason = coalesce(nullif(reason, ''), 'Order rejected')
    where kind = 'market'
      and transaction_id = target_order_id
      and status = 'confirmed';
  end if;
end;
$$;

create or replace function public.list_pending_payment_intents(
  target_business_id uuid default null
)
returns table(
  order_id text,
  kind text,
  amount integer,
  order_name text,
  status text,
  virtual_account jsonb,
  virtual_account_issued_at timestamptz,
  created_at timestamptz,
  expires_at timestamptz,
  draft jsonb,
  business_id uuid,
  business_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.release_expired_pending_stay_blocks();

  if target_business_id is not null and not public.has_business_permission(target_business_id,'reservations') and not public.is_admin() then
    raise exception 'You do not have permission to read this business.';
  end if;

  if target_business_id is null and not public.is_admin() then
    return query
    select
      pi.order_id,
      pi.kind,
      pi.amount,
      pi.order_name,
      pi.status,
      pi.virtual_account,
      pi.virtual_account_issued_at,
      pi.created_at,
      pi.expires_at,
      pi.draft,
      b.id,
      b.business_name
    from public.payment_intents pi
    join public.businesses b on b.id::text = pi.draft ->> 'business_id'
    where pi.status = 'virtual_account_issued'
      and public.has_business_permission(b.id,'reservations')
      and b.approval_status = 'approved'
    order by pi.virtual_account_issued_at desc nulls last, pi.created_at desc;
    return;
  end if;

  return query
  select
    pi.order_id,
    pi.kind,
    pi.amount,
    pi.order_name,
    pi.status,
    pi.virtual_account,
    pi.virtual_account_issued_at,
    pi.created_at,
    pi.expires_at,
    pi.draft,
    b.id,
    b.business_name
  from public.payment_intents pi
  join public.businesses b on b.id::text = pi.draft ->> 'business_id'
  where pi.status = 'virtual_account_issued'
    and (target_business_id is null or b.id = target_business_id)
  order by pi.virtual_account_issued_at desc nulls last, pi.created_at desc;
end;
$$;

create or replace function public.list_own_partner_settlements()
returns table(
  id uuid,
  business_id uuid,
  business_name text,
  transaction_kind text,
  transaction_id uuid,
  customer_name text,
  target_name text,
  transaction_date date,
  gross_amount integer,
  customer_paid_amount integer,
  platform_discount_amount integer,
  commission_rate numeric,
  commission_amount integer,
  payout_amount integer,
  status text,
  paid_at timestamptz,
  note text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.status = 'approved'
      and (p.role in ('partner', 'admin') or exists(select 1 from public.business_members m where m.user_id=p.id and m.status='active' and 'settlements'=any(m.permissions)))
  ) then
    raise exception '사장님 또는 운영자 권한이 필요합니다.';
  end if;

  perform public.sync_partner_settlements();

  return query
  select
    s.id,
    s.business_id,
    b.business_name,
    s.transaction_kind,
    s.transaction_id,
    coalesce(r.customer_name, o.customer_name, '이용자') as customer_name,
    coalesce(
      r.offering_name,
      (
        select string_agg(moi.item_name || ' ' || moi.quantity || '개', ', ' order by moi.item_name)
        from public.market_order_items moi
        where moi.order_id = o.id
      ),
      '거래'
    ) as target_name,
    coalesce(r.event_date, o.created_at::date, s.created_at::date) as transaction_date,
    s.gross_amount,
    coalesce(s.customer_paid_amount, s.gross_amount) as customer_paid_amount,
    coalesce(s.platform_discount_amount, 0) as platform_discount_amount,
    s.commission_rate,
    s.commission_amount,
    s.payout_amount,
    s.status,
    s.paid_at,
    s.note,
    s.created_at
  from public.partner_settlements s
  join public.businesses b on b.id = s.business_id
  left join public.reservations r
    on s.transaction_kind = 'stay' and r.id = s.transaction_id
  left join public.market_orders o
    on s.transaction_kind = 'market' and o.id = s.transaction_id
  where s.status <> 'cancelled'
    and (public.has_business_permission(b.id,'settlements') or public.is_admin())
  order by s.created_at desc;
end;
$$;

create or replace function public.can_access_conversation(target_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.status='approved')
 and exists(select 1 from public.conversations c where c.id=target_id and (
 public.is_admin() or public.has_business_permission(c.business_id,'chat')
 or case when c.organization_id is null then c.customer_id=auth.uid() else public.is_organization_member(c.organization_id) end));
$$;

create or replace function public.send_chat_message(target_conversation_id uuid,message_body text)
returns uuid language plpgsql security definer set search_path='' as $$
declare person public.profiles%rowtype; convo public.conversations%rowtype; result_id uuid; actual_role text;
begin
 if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화에 메시지를 보낼 권한이 없습니다.'; end if;
 if nullif(btrim(message_body),'') is null or length(btrim(message_body))>4000 then raise exception '메시지는 1~4000자로 입력해주세요.'; end if;
 select * into person from public.profiles where id=auth.uid();
 select * into convo from public.conversations where id=target_conversation_id;
 actual_role:=case when public.is_admin() then 'admin' when public.has_business_permission(convo.business_id,'chat') then 'partner' else 'user' end;
 insert into public.messages(conversation_id,sender_id,sender_role,sender_name,body)
 values(convo.id,auth.uid(),actual_role,coalesce(nullif(person.full_name,''),'담당자'),btrim(message_body)) returning id into result_id;
 update public.conversations set last_message_at=now() where id=convo.id;
 return result_id;
end;
$$;

create or replace function public.mark_conversation_read(target_conversation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare convo public.conversations%rowtype; representative uuid; business_side boolean;
begin
 if not public.can_access_conversation(target_conversation_id) then raise exception '이 대화를 확인할 권한이 없습니다.'; end if;
 select * into convo from public.conversations where id=target_conversation_id;
 business_side:=public.has_business_permission(convo.business_id,'chat') or public.is_admin();
 if convo.organization_id is null then
 update public.messages set read_at=now() where conversation_id=convo.id and sender_id<>auth.uid() and read_at is null;
 else
 update public.messages set read_at=now() where conversation_id=convo.id and read_at is null
 and (case when business_side then sender_role='user' else sender_role in ('partner','admin') end);
 end if;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,active_until,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,auth.uid(),now()+interval '75 seconds',now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set active_until=excluded.active_until,last_read_at=now(),last_notified_message_id=null,updated_at=now();
 if convo.organization_id is not null and not business_side then
 select representative_id into representative from public.organizations where id=convo.organization_id;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,representative,now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set last_read_at=now(),last_notified_message_id=null,updated_at=now();
 end if;
 if business_side then
 select owner_id into representative from public.businesses where id=convo.business_id;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,last_read_at,last_notified_message_id,updated_at)
 values(convo.id,representative,now(),null,now())
 on conflict(conversation_id,recipient_user_id) do update set last_read_at=now(),last_notified_message_id=null,updated_at=now();
 end if;
end;
$$;

create or replace function public.start_partner_transaction_conversation(target_kind text,target_transaction_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare tx jsonb; bid uuid; cid uuid; oid uuid; rid uuid; result_id uuid; group_label text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;
 if target_kind='stay' then
 select to_jsonb(r) into tx from public.reservations r where id=target_transaction_id;
 rid:=target_transaction_id;
 elsif target_kind='market' then
 select to_jsonb(r) into tx from public.market_orders r where id=target_transaction_id;
 else raise exception '거래 종류를 확인해주세요.';
 end if;
 bid:=(tx->>'business_id')::uuid; cid:=(tx->>'customer_id')::uuid; oid:=(tx->>'organization_id')::uuid;
 if tx is null or not (public.has_business_permission(bid,'chat') or public.is_admin()) then raise exception '해당 업장의 거래만 확인할 수 있습니다.'; end if;
 if oid is null then
 if not exists(select 1 from public.profiles where id=cid and status='approved') then raise exception '현재 연락 가능한 이용자 계정이 없습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(cid::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and customer_id=cid and organization_id is null order by created_at limit 1;
 group_label:=tx->>'group_name';
 else
 select name into group_label from public.organizations where id=oid;
 perform pg_advisory_xact_lock(hashtextextended(oid::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and organization_id=oid;
 end if;
 if result_id is null then
 insert into public.conversations(business_id,customer_id,organization_id,reservation_id,customer_name,group_name)
 values(bid,cid,oid,rid,coalesce(tx->>'customer_name','이용자'),group_label) returning id into result_id;
 elsif rid is not null then
 update public.conversations set reservation_id=coalesce(reservation_id,rid) where id=result_id;
 end if;
 return result_id;
end;
$$;

create or replace function public.start_partner_pending_conversation(target_order_id text)
returns uuid language plpgsql security definer set search_path='' as $$
declare intent public.payment_intents%rowtype; bid uuid; result_id uuid; group_label text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;
 select * into intent from public.payment_intents where order_id=target_order_id;
 bid:=(intent.draft->>'business_id')::uuid;
 if intent.id is null or not (public.has_business_permission(bid,'chat') or public.is_admin()) then raise exception '해당 업장의 결제 내역만 확인할 수 있습니다.'; end if;
 if intent.transaction_id is not null then return public.start_partner_transaction_conversation(intent.kind,intent.transaction_id); end if;
 if intent.status not in ('prepared','ready','in_progress','virtual_account_issued','waiting_for_deposit') then raise exception '종료된 결제 준비 내역입니다.'; end if;
 if intent.organization_id is null then
 if not exists(select 1 from public.profiles where id=intent.customer_id and status='approved') then raise exception '현재 연락 가능한 이용자 계정이 없습니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(intent.customer_id::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and customer_id=intent.customer_id and organization_id is null order by created_at limit 1;
 group_label:=intent.draft->>'group_name';
 else
 select name into group_label from public.organizations where id=intent.organization_id;
 perform pg_advisory_xact_lock(hashtextextended(intent.organization_id::text||':'||bid::text,0));
 select id into result_id from public.conversations where business_id=bid and organization_id=intent.organization_id;
 end if;
 if result_id is null then
 insert into public.conversations(business_id,customer_id,organization_id,customer_name,group_name)
 values(bid,intent.customer_id,intent.organization_id,coalesce(intent.draft->>'customer_name','이용자'),group_label) returning id into result_id;
 end if;
 return result_id;
end;
$$;

create or replace function public.enqueue_chat_message_notifications()
returns trigger language plpgsql security definer set search_path='' as $$
declare convo public.conversations%rowtype; business public.businesses%rowtype; recipient public.profiles%rowtype;
 state public.chat_notification_state%rowtype; recipient_id uuid; recipient_role text; recipient_name text;
 phone text; template text; button text; link text; related text; payload jsonb; viewing boolean;
begin
 select * into convo from public.conversations where id=new.conversation_id;
 select * into business from public.businesses where id=convo.business_id;
 if convo.id is null or business.id is null then return new; end if;
 related:=case when convo.reservation_id is not null then '예약 '||left(convo.reservation_id::text,8) else business.business_name end;
 if new.sender_role='user' then
 recipient_id:=business.owner_id; recipient_role:='owner'; template:='OWNER_CHAT_RECEIVED_V1'; button:='문의 확인';
 select * into recipient from public.profiles where id=recipient_id and status='approved';
 recipient_name:=coalesce(nullif(recipient.full_name,''),business.representative_name,'사장님');
 phone:=coalesce(nullif(recipient.phone,''),business.phone);
 link:=public.notification_owner_url('/?open=chat&conversationId='||convo.id::text);
 payload:=jsonb_build_object('사장님명',recipient_name,'고객명',coalesce(nullif(new.sender_name,''),convo.customer_name,'이용자'),'관련건',related);
 else
 if not exists(select 1 from public.messages where conversation_id=convo.id and sender_role='user') then return new; end if;
 recipient_id:=convo.customer_id;
 if convo.organization_id is not null then
 select representative_id into recipient_id from public.organizations where id=convo.organization_id;
 if not public.is_organization_member(convo.organization_id,recipient_id) then return new; end if;
 end if;
 recipient_role:='user'; template:='USER_CHAT_RECEIVED_V1'; button:='답변 확인';
 select * into recipient from public.profiles where id=recipient_id and status='approved';
 recipient_name:=coalesce(nullif(recipient.full_name,''),convo.customer_name,'이용자'); phone:=recipient.phone;
 link:=public.notification_user_url('/?route=chat&conversationId='||convo.id::text||case when convo.organization_id is not null then '&organizationId='||convo.organization_id::text else '' end);
 payload:=jsonb_build_object('고객명',coalesce((select name from public.organizations where id=convo.organization_id),recipient_name),'상대명',business.business_name,'관련건',related);
 end if;
 if recipient.id is null or nullif(trim(coalesce(phone,'')),'') is null then return new; end if;
 insert into public.chat_notification_state(conversation_id,recipient_user_id,updated_at)
 values(convo.id,recipient_id,now()) on conflict do nothing;
 select * into state from public.chat_notification_state where conversation_id=convo.id and recipient_user_id=recipient_id for update;
 viewing:=coalesce(state.active_until>now(),false);
 if recipient_role='user' and convo.organization_id is not null then
 viewing:=viewing or exists(select 1 from public.chat_notification_state s
 where s.conversation_id=convo.id and s.active_until>now() and public.is_organization_member(convo.organization_id,s.recipient_user_id));
 end if;
 if recipient_role='owner' then
 viewing:=viewing or exists(select 1 from public.chat_notification_state s where s.conversation_id=convo.id and s.active_until>now() and public.has_business_permission_for(convo.business_id,'chat',s.recipient_user_id));
 end if;
 if viewing then
 update public.messages set read_at=coalesce(read_at,now()) where conversation_id=convo.id and read_at is null
 and (case when recipient_role='owner' then sender_role='user' else sender_role in ('partner','admin') end);
 update public.chat_notification_state set last_read_at=now(),last_notified_message_id=null,updated_at=now()
 where conversation_id=convo.id and recipient_user_id=recipient_id;
 return new;
 end if;
 if state.last_notified_message_id is not null then return new; end if;
 perform public.enqueue_notification(
 target_event_key:='chat_received',target_template_key:=template,target_recipient_role:=recipient_role,
 target_recipient_user_id:=recipient_id,target_recipient_name:=recipient_name,target_recipient_phone:=phone,
 target_payload:=payload,target_button_links:=jsonb_build_object(button,link),
 target_dedupe_key:='chat:'||convo.id::text||':'||recipient_id::text||':'||new.id::text);
 update public.chat_notification_state set last_notified_message_id=new.id,updated_at=now() where conversation_id=convo.id and recipient_user_id=recipient_id;
 return new;
end;
$$;

-- Staff reads are separate from customer/representative policies.
drop policy if exists reservations_staff_read on public.reservations;
create policy reservations_staff_read on public.reservations for select to authenticated using(
 public.has_business_permission(business_id,'reservations') or public.has_business_permission(business_id,'settlements'));
drop policy if exists market_orders_staff_read on public.market_orders;
create policy market_orders_staff_read on public.market_orders for select to authenticated using(
 public.has_business_permission(business_id,'reservations') or public.has_business_permission(business_id,'settlements'));
drop policy if exists market_order_items_staff_read on public.market_order_items;
create policy market_order_items_staff_read on public.market_order_items for select to authenticated using(exists(
 select 1 from public.market_orders o where o.id=order_id and
 (public.has_business_permission(o.business_id,'reservations') or public.has_business_permission(o.business_id,'settlements'))));
drop policy if exists payment_intents_staff_read on public.payment_intents;
create policy payment_intents_staff_read on public.payment_intents for select to authenticated using(
 public.has_business_permission(case when draft->>'business_id' ~ '^[0-9a-fA-F-]{36}$' then (draft->>'business_id')::uuid end,'reservations'));
drop policy if exists partner_settlements_staff_read on public.partner_settlements;
create policy partner_settlements_staff_read on public.partner_settlements for select to authenticated using(
 public.has_business_permission(business_id,'settlements'));
drop policy if exists offerings_staff_read on public.offerings;
create policy offerings_staff_read on public.offerings for select to authenticated using(public.can_access_business_workspace(business_id));
drop policy if exists offerings_staff_insert on public.offerings;
create policy offerings_staff_insert on public.offerings for insert to authenticated with check(public.has_business_permission(business_id,'listing'));
drop policy if exists offerings_staff_update on public.offerings;
create policy offerings_staff_update on public.offerings for update to authenticated
 using(public.has_business_permission(business_id,'listing') or public.has_business_permission(business_id,'availability'))
 with check(public.has_business_permission(business_id,'listing') or public.has_business_permission(business_id,'availability'));
drop policy if exists stay_blocks_staff_read on public.stay_availability_blocks;
create policy stay_blocks_staff_read on public.stay_availability_blocks for select to authenticated using(
 public.has_business_permission(business_id,'availability') or public.has_business_permission(business_id,'reservations'));
drop policy if exists stay_blocks_staff_write on public.stay_availability_blocks;
create policy stay_blocks_staff_write on public.stay_availability_blocks for all to authenticated
 using(source='manual' and public.has_business_permission(business_id,'availability'))
 with check(source='manual' and public.has_business_permission(business_id,'availability'));
drop policy if exists listing_reviews_staff_read on public.business_listing_review_requests;
create policy listing_reviews_staff_read on public.business_listing_review_requests for select to authenticated
 using(public.has_business_permission(business_id,'listing'));
drop policy if exists business_documents_staff_read on public.business_verification_documents;
create policy business_documents_staff_read on public.business_verification_documents for select to authenticated
 using(public.has_business_permission(business_id,'listing'));
drop policy if exists business_documents_staff_insert on public.business_verification_documents;
create policy business_documents_staff_insert on public.business_verification_documents for insert to authenticated
 with check(public.has_business_permission(business_id,'listing'));

-- Transaction status/refund amounts are changed only through authorized RPCs or the payment server.
revoke update on public.reservations,public.market_orders from authenticated;
-- Ownership can change only inside the handover/admin RPC, never through a direct PATCH.
revoke update on public.businesses from authenticated;
revoke update(owner_id) on public.businesses from authenticated;
do $$ declare columns text; begin
 select string_agg(quote_ident(a.attname),',') into columns from pg_attribute a
 where a.attrelid='public.businesses'::regclass and a.attnum>0 and not a.attisdropped
 and a.attname not in ('id','owner_id','business_type','owner_workspace_created','workspace_closed_at');
 execute 'grant update ('||columns||') on public.businesses to authenticated';
end $$;
create or replace function public.guard_staff_offering_fields()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or public.is_admin() then return new; end if;
 if new.business_id<>old.business_id or new.id<>old.id then raise exception '상품 소속을 변경할 수 없습니다.'; end if;
 if public.owns_business(old.business_id) then return new; end if;
 if public.has_business_permission(old.business_id,'listing') then return new; end if;
 if not public.has_business_permission(old.business_id,'availability')
 or (to_jsonb(new)-array['stock_quantity','is_active','updated_at']) is distinct from
 (to_jsonb(old)-array['stock_quantity','is_active','updated_at']) then raise exception '상품 수정 권한이 없습니다.' using errcode='42501'; end if;
 return new;
end;
$$;
drop trigger if exists guard_staff_offering_fields on public.offerings;
create trigger guard_staff_offering_fields before update on public.offerings for each row execute function public.guard_staff_offering_fields();

create or replace function public.cancel_stay_availability_block(target_block_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare b public.stay_availability_blocks%rowtype;
begin
 select * into b from public.stay_availability_blocks where id=target_block_id for update;
 if b.id is null or b.source<>'manual' then raise exception '수동 방막기만 해제할 수 있습니다.'; end if;
 if not public.has_business_permission(b.business_id,'availability') and not public.is_admin() then raise exception '방막기 권한이 없습니다.'; end if;
 update public.stay_availability_blocks set status='cancelled' where id=b.id;
end;
$$;
revoke all on function public.cancel_stay_availability_block(uuid) from public,anon;
grant execute on function public.cancel_stay_availability_block(uuid) to authenticated;

create or replace function public.audit_business_workspace_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare bid uuid; item_id uuid; keys jsonb; rowdata jsonb;
begin
 rowdata:=to_jsonb(new);
 bid:=case when tg_table_name='businesses' then (rowdata->>'id')::uuid else (rowdata->>'business_id')::uuid end;
 item_id:=case when tg_table_name='business_settlement_accounts' then bid else (rowdata->>'id')::uuid end;
 if tg_op='UPDATE' then
 select coalesce(jsonb_agg(n.key),'[]'::jsonb) into keys from jsonb_each(rowdata) n
 where n.value is distinct from to_jsonb(old)->n.key and n.key<>'updated_at';
 else select coalesce(jsonb_agg(n.key),'[]'::jsonb) into keys from jsonb_each(rowdata) n; end if;
 if keys<>'[]'::jsonb then
 insert into public.business_workspace_audit(business_id,actor_id,action,subject_id,details)
 values(bid,auth.uid(),tg_table_name||':'||lower(tg_op),item_id,jsonb_build_object('changed_fields',keys));
 end if;
 return new;
end;
$$;
do $$ declare t text; begin
 foreach t in array array['businesses','offerings','reservations','market_orders','stay_availability_blocks','business_settlement_accounts','business_listing_review_requests'] loop
 execute format('drop trigger if exists audit_business_workspace_change on public.%I',t);
 execute format('create trigger audit_business_workspace_change after insert or update on public.%I for each row execute function public.audit_business_workspace_change()',t);
 end loop;
end $$;

create or replace function public.clear_transferred_business_chat()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.owner_id is distinct from old.owner_id then
 update public.chat_notification_state s set active_until=null,updated_at=now() from public.conversations c
 where s.conversation_id=c.id and c.business_id=new.id and s.recipient_user_id=old.owner_id;
 update public.notification_outbox n set status='cancelled',last_error='Business representative changed',updated_at=now()
 where n.status='queued' and n.template_key='OWNER_CHAT_RECEIVED_V1' and n.recipient_user_id=old.owner_id
 and n.dedupe_key like 'chat:%' and exists(select 1 from public.conversations c where c.business_id=new.id
 and n.dedupe_key like 'chat:'||c.id::text||':%');
 update public.business_staff_invitations set status='revoked' where business_id=new.id and status='pending';
 update public.business_ownership_transfers set status='cancelled' where business_id=new.id and status in ('requested','accepted')
 and to_user_id<>new.owner_id;
 end if;
 return new;
end;
$$;
drop trigger if exists clear_transferred_business_chat on public.businesses;
create trigger clear_transferred_business_chat after update of owner_id on public.businesses for each row execute function public.clear_transferred_business_chat();
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('save_business_offerings','refresh_business_nearby_distances','refresh_business_highlights',
 'submit_business_listing_review','create_stay_manual_block','set_reservation_status','set_market_order_status',
 'list_pending_payment_intents','list_own_partner_settlements','can_access_conversation','send_chat_message',
 'mark_conversation_read','start_partner_transaction_conversation','start_partner_pending_conversation') loop
 execute format('revoke all on function %s from public,anon',f.signature);
 execute format('grant execute on function %s to authenticated,service_role',f.signature);
 end loop;
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('audit_business_workspace_change','guard_staff_offering_fields','clear_transferred_business_chat') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 end loop;
end $$;
commit;
