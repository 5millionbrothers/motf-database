-- Catalog editing, stable offering IDs, structured pricing, support chat and MT archive hardening.

create table if not exists public.stay_availability_blocks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  offering_id uuid not null references public.offerings(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  start_date date not null,
  end_date date not null,
  source text not null default 'manual',
  status text not null default 'active',
  note text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date < end_date)
);

alter table public.stay_availability_blocks
  add column if not exists reservation_id uuid references public.reservations(id) on delete set null,
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists payment_intent_id uuid references public.payment_intents(id) on delete set null,
  add column if not exists payment_order_id text;

alter table public.stay_availability_blocks drop constraint if exists stay_availability_blocks_source_check;
alter table public.stay_availability_blocks add constraint stay_availability_blocks_source_check
check (source in ('manual', 'motf', 'pending_payment', 'external_ical', 'external_api'));

alter table public.stay_availability_blocks drop constraint if exists stay_availability_blocks_status_check;
alter table public.stay_availability_blocks add constraint stay_availability_blocks_status_check
check (status in ('active', 'cancelled'));

create index if not exists stay_blocks_offering_range_idx
on public.stay_availability_blocks(offering_id, start_date, end_date) where status = 'active';
create index if not exists stay_blocks_business_range_idx
on public.stay_availability_blocks(business_id, start_date, end_date) where status = 'active';

drop trigger if exists stay_availability_blocks_set_updated_at on public.stay_availability_blocks;
create trigger stay_availability_blocks_set_updated_at before update on public.stay_availability_blocks
for each row execute procedure public.set_updated_at();

alter table public.stay_availability_blocks enable row level security;
drop policy if exists "stay_blocks_read_managers" on public.stay_availability_blocks;
create policy "stay_blocks_read_managers" on public.stay_availability_blocks
for select to authenticated using (public.owns_business(business_id) or public.is_admin());
drop policy if exists "stay_blocks_write_managers" on public.stay_availability_blocks;
create policy "stay_blocks_write_managers" on public.stay_availability_blocks
for all to authenticated using (public.owns_business(business_id) or public.is_admin())
with check (public.owns_business(business_id) or public.is_admin());
grant select, insert, update on public.stay_availability_blocks to authenticated;

alter table public.businesses
  add column if not exists short_description text,
  add column if not exists highlight_summary text[] not null default '{}',
  add column if not exists is_internal boolean not null default false;

alter table public.businesses drop constraint if exists businesses_short_description_length_check;
alter table public.businesses add constraint businesses_short_description_length_check
check (short_description is null or char_length(short_description) <= 140);
alter table public.businesses drop constraint if exists businesses_highlight_summary_limit_check;
alter table public.businesses add constraint businesses_highlight_summary_limit_check
check (cardinality(highlight_summary) <= 3);

alter table public.offerings
  add column if not exists base_people integer check (base_people is null or base_people > 0),
  add column if not exists extra_person_fee integer check (extra_person_fee is null or extra_person_fee >= 0);

alter table public.mt_notices
  add column if not exists title text,
  add column if not exists notice_date date;

alter table public.mt_notices drop constraint if exists mt_notices_title_length_check;
alter table public.mt_notices add constraint mt_notices_title_length_check
check (title is null or char_length(trim(title)) between 1 and 120);

grant select (short_description, highlight_summary) on public.businesses to anon, authenticated;
grant update (short_description, highlight_summary, updated_at) on public.businesses to authenticated;
grant select (base_people, extra_person_fee) on public.offerings to anon, authenticated;

-- Keep existing offering IDs so reservations and availability blocks never lose their room link.
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
begin
  if not public.owns_business(target_business_id) and not public.is_admin() then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;

  for item in select value from jsonb_array_elements(items)
  loop
    if nullif(trim(item->>'name'), '') is null then
      raise exception '객실 또는 상품 이름을 입력해주세요.';
    end if;

    item_id := nullif(item->>'id', '')::uuid;
    if item_id is not null and not exists (
      select 1 from public.offerings o where o.id = item_id and o.business_id = target_business_id
    ) then
      raise exception '수정할 수 없는 객실 또는 상품입니다.';
    end if;
    item_id := coalesce(item_id, gen_random_uuid());

    select coalesce(array_agg(value), '{}') into feature_values
    from jsonb_array_elements_text(
      case when jsonb_typeof(item->'feature_summary') = 'array' then item->'feature_summary' else '[]'::jsonb end
    );
    select coalesce(array_agg(value), '{}') into image_values
    from jsonb_array_elements_text(
      case when jsonb_typeof(item->'image_urls') = 'array' then item->'image_urls' else '[]'::jsonb end
    );

    insert into public.offerings (
      id, business_id, name, description, price, is_active, max_people, min_people,
      base_people, extra_person_fee, unit, category, image_url, image_urls, sort_order,
      feature_summary, amenity_details, detail_sections, origin, nutrition_info,
      is_alcohol, stock_quantity, updated_at
    ) values (
      item_id, target_business_id, trim(item->>'name'), nullif(trim(item->>'description'), ''),
      greatest(coalesce(nullif(item->>'price', '')::integer, 0), 0),
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
      coalesce(nullif(item->>'is_alcohol', '')::boolean, false),
      nullif(item->>'stock_quantity', '')::integer, now()
    )
    on conflict (id) do update set
      name = excluded.name,
      description = excluded.description,
      price = excluded.price,
      is_active = excluded.is_active,
      max_people = excluded.max_people,
      min_people = excluded.min_people,
      base_people = excluded.base_people,
      extra_person_fee = excluded.extra_person_fee,
      unit = excluded.unit,
      category = excluded.category,
      image_url = excluded.image_url,
      image_urls = excluded.image_urls,
      sort_order = excluded.sort_order,
      feature_summary = excluded.feature_summary,
      amenity_details = excluded.amenity_details,
      detail_sections = excluded.detail_sections,
      origin = excluded.origin,
      nutrition_info = excluded.nutrition_info,
      is_alcohol = excluded.is_alcohol,
      stock_quantity = excluded.stock_quantity,
      updated_at = now();

    submitted_ids := array_append(submitted_ids, item_id);
  end loop;

  update public.offerings
  set is_active = false, updated_at = now()
  where business_id = target_business_id and not (id = any(submitted_ids));
end;
$$;

revoke all on function public.save_business_offerings(uuid,jsonb) from public;
grant execute on function public.save_business_offerings(uuid,jsonb) to authenticated;

-- A platform support conversation uses the same tested chat/read-receipt path.
alter table public.businesses drop constraint if exists businesses_business_type_check;
alter table public.businesses add constraint businesses_business_type_check
check (business_type in ('stay', 'market', 'support'));

create or replace function public.start_support_conversation()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  support_owner uuid;
  support_business uuid;
  support_conversation uuid;
  caller_name text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;

  select p.id into support_owner from public.profiles p where p.role = 'admin' and p.status = 'approved' order by p.created_at limit 1;
  if support_owner is null then raise exception '운영팀 계정이 준비되지 않았습니다.'; end if;

  select b.id into support_business from public.businesses b where b.business_type = 'support' and b.is_internal = true limit 1;
  if support_business is null then
    insert into public.businesses (
      owner_id, business_type, business_name, representative_name, phone,
      address, description, region, approval_status, is_internal
    ) values (
      support_owner, 'support', '모티프 운영팀', '모티프 운영팀', '010-3357-2537',
      '서울특별시 중구 소공로 46 A-1102', '서비스 이용 문의와 운영 지원을 위한 공식 채팅입니다.',
      '전국', 'approved', true
    ) returning id into support_business;
  end if;

  select coalesce(p.full_name, p.email, '회원') into caller_name from public.profiles p where p.id = auth.uid();
  select c.id into support_conversation from public.conversations c
  where c.business_id = support_business and c.customer_id = auth.uid() limit 1;

  if support_conversation is null then
    insert into public.conversations (business_id, customer_id, customer_name, group_name)
    values (support_business, auth.uid(), coalesce(caller_name, '회원'), '운영 문의')
    returning id into support_conversation;
  end if;
  return support_conversation;
end;
$$;

revoke all on function public.start_support_conversation() from public;
grant execute on function public.start_support_conversation() to authenticated;

-- 공개 리뷰는 작성자 계정 정보나 원본 거래 행을 노출하지 않는 읽기 전용 응답으로 제공한다.
create or replace function public.get_public_reviews(limit_count integer default 40)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(review_row order by created_at desc), '[]'::jsonb)
  from (
    select r.created_at,
      jsonb_build_object(
        'id', r.id,
        'business_id', r.business_id,
        'transaction_type', case when r.market_order_id is not null then 'market' else 'stay' end,
        'author_name', coalesce(nullif(r.author_name, ''), 'moTF 이용자'),
        'rating', r.rating,
        'body', r.body,
        'tags', coalesce(r.tags, '{}'),
        'image_urls', coalesce(r.image_urls, '{}'),
        'structured_scores', coalesce(r.structured_scores, '{}'::jsonb),
        'comfortable_people_min', r.comfortable_people_min,
        'comfortable_people_max', r.comfortable_people_max,
        'recommend_30_plus', r.recommend_30_plus,
        'organizer_difficulty', r.organizer_difficulty,
        'created_at', r.created_at,
        'business_name', b.business_name
      ) as review_row
    from public.reviews r
    join public.businesses b on b.id = r.business_id
    where coalesce(r.is_hidden, false) = false
      and b.approval_status = 'approved'
    order by r.created_at desc
    limit greatest(1, least(coalesce(limit_count, 40), 100))
  ) public_reviews;
$$;

revoke all on function public.get_public_reviews(integer) from public;
grant execute on function public.get_public_reviews(integer) to anon, authenticated;

-- 결제 금액은 브라우저 계산값이 아니라 객실 기본요금과 구조화된 추가인원 요금으로 서버에서 확정한다.
create or replace function public.prepare_stay_payment(
  target_business_id uuid,
  target_offering_id uuid,
  customer_name text,
  group_name text,
  contact_phone text,
  event_date date,
  guest_count integer,
  request_memo text default null,
  check_in_date date default null,
  check_out_date date default null
)
returns table(order_id text, amount integer, order_name text, kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_offering public.offerings%rowtype;
  selected_business public.businesses%rowtype;
  new_order_id text;
  actual_check_in date := coalesce(check_in_date, event_date);
  actual_check_out date := coalesce(check_out_date, event_date + 1);
  included_people integer;
  extra_people integer;
  calculated_amount integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'user' and status = 'approved'
  ) then raise exception '현재 계정으로 예약할 수 없습니다.'; end if;
  if nullif(trim(customer_name), '') is null then raise exception '대표자 이름이 필요합니다.'; end if;
  if actual_check_in < current_date then raise exception '지난 날짜는 예약할 수 없습니다.'; end if;
  if actual_check_in >= actual_check_out then raise exception '숙박 일정을 다시 확인해주세요.'; end if;
  if guest_count is null or guest_count <= 0 then raise exception '예약 인원이 필요합니다.'; end if;

  select o.* into selected_offering
  from public.offerings o
  where o.id = target_offering_id and o.business_id = target_business_id and o.is_active;

  select b.* into selected_business
  from public.businesses b
  where b.id = target_business_id and b.business_type = 'stay' and b.approval_status = 'approved';

  if selected_offering.id is null or selected_business.id is null then raise exception '예약 가능한 객실을 찾지 못했습니다.'; end if;
  if selected_offering.max_people is not null and guest_count > selected_offering.max_people then raise exception '객실 최대 인원을 초과했습니다.'; end if;
  if selected_offering.price <= 0 then raise exception '객실 요금이 올바르지 않습니다.'; end if;
  if not public.stay_range_is_available(selected_offering.id, actual_check_in, actual_check_out) then raise exception '선택한 날짜에 이미 예약된 객실입니다.'; end if;

  included_people := greatest(1, coalesce(selected_offering.base_people, selected_offering.min_people, selected_offering.max_people, guest_count));
  extra_people := greatest(0, guest_count - included_people);
  calculated_amount := selected_offering.price + (extra_people * greatest(0, coalesce(selected_offering.extra_person_fee, 0)));

  loop
    new_order_id := 'MS-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (select 1 from public.payment_intents pi where pi.order_id = new_order_id);
  end loop;

  insert into public.payment_intents (order_id, customer_id, kind, amount, order_name, draft)
  values (
    new_order_id, auth.uid(), 'stay', calculated_amount,
    left(selected_business.business_name || ' ' || selected_offering.name, 100),
    jsonb_build_object(
      'business_id', selected_business.id,
      'offering_id', selected_offering.id,
      'offering_name', selected_offering.name,
      'customer_name', trim(customer_name),
      'group_name', nullif(trim(group_name), ''),
      'contact_phone', nullif(trim(contact_phone), ''),
      'event_date', actual_check_in,
      'check_in_date', actual_check_in,
      'check_out_date', actual_check_out,
      'guest_count', guest_count,
      'base_people', included_people,
      'extra_people', extra_people,
      'extra_person_fee', coalesce(selected_offering.extra_person_fee, 0),
      'request_memo', nullif(trim(request_memo), '')
    )
  );

  return query select new_order_id, calculated_amount, left(selected_business.business_name || ' ' || selected_offering.name, 100), 'stay'::text;
end;
$$;

revoke all on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text,date,date) from public;
grant execute on function public.prepare_stay_payment(uuid,uuid,text,text,text,date,integer,text,date,date) to authenticated;

comment on column public.businesses.highlight_summary is 'Up to three short facts shown on listing cards';
comment on column public.offerings.base_people is 'People included in the base room price';
comment on column public.offerings.extra_person_fee is 'Additional charge per person above base_people';
