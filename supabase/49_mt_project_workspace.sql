-- moTF 중심 기능: 한 팀의 숙소 후보, 장보기, 예산, 일정과 공지를 묶는 MT 프로젝트.

create table if not exists public.mt_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 2 and 120),
  organization_name text,
  region text,
  starts_on date not null,
  ends_on date not null,
  guest_count integer not null check (guest_count > 0),
  status text not null default 'planning' check (status in ('planning','booking','confirmed','completed','cancelled')),
  final_business_id uuid references public.businesses(id) on delete set null,
  final_reservation_id uuid references public.reservations(id) on delete set null,
  estimated_budget integer not null default 0 check (estimated_budget >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on > starts_on)
);

create table if not exists public.mt_project_candidates (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  offering_id uuid references public.offerings(id) on delete set null,
  estimated_cost jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique(project_id, business_id)
);

create table if not exists public.mt_project_items (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  item_kind text not null check (item_kind in ('stay','shopping','transport','activity','other')),
  reference_id uuid,
  title text not null,
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  amount integer not null default 0 check (amount >= 0),
  status text not null default 'planned' check (status in ('planned','pending','confirmed','completed','cancelled')),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mt_itinerary_items (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  starts_at timestamptz not null,
  title text not null,
  place text,
  note text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mt_notices (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  is_pinned boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.businesses
  add column if not exists gallery_image_urls text[] not null default '{}',
  add column if not exists business_number_status_checked_at timestamptz,
  add column if not exists business_number_verified_at timestamptz,
  add column if not exists business_number_verification_status text not null default 'pending';

alter table public.businesses drop constraint if exists businesses_business_number_verification_status_check;
alter table public.businesses add constraint businesses_business_number_verification_status_check
check (business_number_verification_status in ('pending','active_checked','verified','failed'));

alter table public.offerings
  add column if not exists image_urls text[] not null default '{}';

alter table public.reservations
  add column if not exists project_id uuid references public.mt_projects(id) on delete set null,
  add column if not exists end_date date,
  add column if not exists owner_request_note text;

alter table public.market_orders
  add column if not exists project_id uuid references public.mt_projects(id) on delete set null;

alter table public.reviews
  add column if not exists market_order_id uuid references public.market_orders(id) on delete set null,
  add column if not exists tags text[] not null default '{}',
  add column if not exists image_urls text[] not null default '{}',
  add column if not exists structured_scores jsonb not null default '{}'::jsonb,
  add column if not exists comfortable_people_min integer check (comfortable_people_min is null or comfortable_people_min > 0),
  add column if not exists comfortable_people_max integer check (comfortable_people_max is null or comfortable_people_max > 0),
  add column if not exists recommend_30_plus boolean,
  add column if not exists organizer_difficulty integer check (organizer_difficulty is null or organizer_difficulty between 1 and 5);

alter table public.reviews drop constraint if exists reviews_rating_check;
alter table public.reviews add constraint reviews_rating_check check (rating between 1 and 10);

create index if not exists mt_projects_owner_starts_idx on public.mt_projects(owner_id, starts_on desc);
create index if not exists mt_candidates_project_sort_idx on public.mt_project_candidates(project_id, sort_order);
create index if not exists mt_items_project_kind_idx on public.mt_project_items(project_id, item_kind);
create index if not exists mt_itinerary_project_start_idx on public.mt_itinerary_items(project_id, starts_at);

drop trigger if exists mt_projects_set_updated_at on public.mt_projects;
create trigger mt_projects_set_updated_at before update on public.mt_projects
for each row execute procedure public.set_updated_at();
drop trigger if exists mt_items_set_updated_at on public.mt_project_items;
create trigger mt_items_set_updated_at before update on public.mt_project_items
for each row execute procedure public.set_updated_at();
drop trigger if exists mt_itinerary_set_updated_at on public.mt_itinerary_items;
create trigger mt_itinerary_set_updated_at before update on public.mt_itinerary_items
for each row execute procedure public.set_updated_at();
drop trigger if exists mt_notices_set_updated_at on public.mt_notices;
create trigger mt_notices_set_updated_at before update on public.mt_notices
for each row execute procedure public.set_updated_at();

alter table public.mt_projects enable row level security;
alter table public.mt_project_candidates enable row level security;
alter table public.mt_project_items enable row level security;
alter table public.mt_itinerary_items enable row level security;
alter table public.mt_notices enable row level security;

drop policy if exists "mt_projects_owner_all" on public.mt_projects;
create policy "mt_projects_owner_all" on public.mt_projects
for all to authenticated using (owner_id = auth.uid() or public.is_admin())
with check (owner_id = auth.uid() or public.is_admin());

drop policy if exists "mt_candidates_owner_all" on public.mt_project_candidates;
create policy "mt_candidates_owner_all" on public.mt_project_candidates
for all to authenticated using (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())))
with check (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())));

drop policy if exists "mt_items_owner_all" on public.mt_project_items;
create policy "mt_items_owner_all" on public.mt_project_items
for all to authenticated using (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())))
with check (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())));

drop policy if exists "mt_itinerary_owner_all" on public.mt_itinerary_items;
create policy "mt_itinerary_owner_all" on public.mt_itinerary_items
for all to authenticated using (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())))
with check (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())));

drop policy if exists "mt_notices_owner_all" on public.mt_notices;
create policy "mt_notices_owner_all" on public.mt_notices
for all to authenticated using (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())))
with check (exists (select 1 from public.mt_projects p where p.id = project_id and (p.owner_id = auth.uid() or public.is_admin())));

grant select, insert, update, delete on public.mt_projects, public.mt_project_candidates, public.mt_project_items, public.mt_itinerary_items, public.mt_notices to authenticated;
-- 공개 달력은 예약자 정보 없이 객실별 마감 날짜만 반환한다.
create or replace function public.get_public_stay_calendar(target_business_id uuid, range_start date, range_end date)
returns table(offering_id uuid, start_date date, end_date date)
language sql
stable
security definer
set search_path = ''
as $$
  select b.offering_id, b.start_date, b.end_date
  from public.stay_availability_blocks b
  join public.businesses biz on biz.id = b.business_id
  where b.business_id = target_business_id and biz.approval_status = 'approved' and b.status = 'active'
    and b.start_date < range_end and b.end_date > range_start
    and (
      b.source <> 'pending_payment'
      or exists (
        select 1 from public.payment_intents pi
        where pi.id = b.payment_intent_id
          and pi.status = 'virtual_account_issued'
          and coalesce(pi.expires_at, pi.virtual_account_issued_at + interval '24 hours', pi.created_at + interval '24 hours') > now()
      )
    );
$$;

grant execute on function public.get_public_stay_calendar(uuid,date,date) to anon, authenticated;

create or replace function public.submit_verified_mt_review(
  target_type text,
  target_transaction_id uuid,
  review_rating integer,
  review_body text,
  review_tags text[] default '{}',
  review_image_urls text[] default '{}',
  review_structured_scores jsonb default '{}'::jsonb,
  review_comfortable_people_min integer default null,
  review_comfortable_people_max integer default null,
  review_recommend_30_plus boolean default null,
  review_organizer_difficulty integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business_id uuid;
  new_review_id uuid;
  display_name text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if review_rating < 1 or review_rating > 10 then raise exception '평점은 1점부터 10점까지 입력해주세요.'; end if;
  if char_length(trim(review_body)) < 5 then raise exception '후기를 5자 이상 입력해주세요.'; end if;
  select coalesce(full_name, 'moTF 이용자') into display_name from public.profiles where id = auth.uid();

  if target_type = 'reservation' then
    select business_id into target_business_id from public.reservations
    where id = target_transaction_id and customer_id = auth.uid() and status = 'completed';
  elsif target_type = 'market_order' then
    select business_id into target_business_id from public.market_orders
    where id = target_transaction_id and customer_id = auth.uid() and status = 'completed';
  else
    raise exception '올바르지 않은 이용 내역입니다.';
  end if;
  if target_business_id is null then raise exception '이용 완료된 내역만 리뷰를 작성할 수 있습니다.'; end if;

  insert into public.reviews (
    author_id, business_id, reservation_id, market_order_id, author_name, rating, body, tags, image_urls,
    structured_scores, comfortable_people_min, comfortable_people_max, recommend_30_plus, organizer_difficulty
  ) values (
    auth.uid(), target_business_id,
    case when target_type = 'reservation' then target_transaction_id else null end,
    case when target_type = 'market_order' then target_transaction_id else null end,
    display_name, review_rating, trim(review_body), coalesce(review_tags, '{}'), coalesce(review_image_urls, '{}'),
    coalesce(review_structured_scores, '{}'::jsonb), review_comfortable_people_min, review_comfortable_people_max,
    review_recommend_30_plus, review_organizer_difficulty
  ) returning id into new_review_id;
  return new_review_id;
end;
$$;

revoke all on function public.submit_verified_mt_review(text,uuid,integer,text,text[],text[],jsonb,integer,integer,boolean,integer) from public;
grant execute on function public.submit_verified_mt_review(text,uuid,integer,text,text[],text[],jsonb,integer,integer,boolean,integer) to authenticated;

create unique index if not exists reviews_reservation_author_unique_idx
on public.reviews(reservation_id, author_id) where reservation_id is not null;
create unique index if not exists reviews_market_order_author_unique_idx
on public.reviews(market_order_id, author_id) where market_order_id is not null;

-- feature_summary(text[])에 jsonb를 직접 넣던 기존 저장 오류를 수정하고 다중 사진을 함께 저장한다.
create or replace function public.save_business_offerings(target_business_id uuid, items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.owns_business(target_business_id) and not public.is_admin() then raise exception '상품 수정 권한이 없습니다.'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then raise exception '하나 이상의 객실 또는 상품이 필요합니다.'; end if;
  delete from public.offerings where business_id = target_business_id;
  insert into public.offerings (
    business_id, name, description, price, is_active, max_people, min_people, unit, category,
    image_url, image_urls, sort_order, feature_summary, amenity_details, detail_sections,
    origin, nutrition_info, is_alcohol, stock_quantity
  )
  select target_business_id, nullif(trim(item->>'name'), ''), nullif(trim(item->>'description'), ''), greatest(coalesce((item->>'price')::integer, 0), 0), true,
    nullif(item->>'max_people','')::integer, nullif(item->>'min_people','')::integer, nullif(trim(item->>'unit'),''), nullif(trim(item->>'category'),''),
    nullif(trim(item->>'image_url'),''), coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(item->'image_urls','[]'::jsonb))), '{}'),
    coalesce((item->>'sort_order')::integer,0), coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(item->'feature_summary','[]'::jsonb))), '{}'),
    coalesce(item->'amenity_details','[]'::jsonb), coalesce(item->'detail_sections','{}'::jsonb), nullif(trim(item->>'origin'),''),
    coalesce(item->'nutrition_info','{}'::jsonb), coalesce((item->>'is_alcohol')::boolean,false), nullif(item->>'stock_quantity','')::integer
  from jsonb_array_elements(items) item;
end;
$$;

revoke all on function public.save_business_offerings(uuid,jsonb) from public;
grant execute on function public.save_business_offerings(uuid,jsonb) to authenticated;

grant select (gallery_image_urls) on public.businesses to anon, authenticated;
grant update (gallery_image_urls, updated_at) on public.businesses to authenticated;
grant select (image_urls) on public.offerings to anon, authenticated;

comment on table public.mt_projects is 'User-owned MT workspace that links lodging, shopping, itinerary, notices and budget';
comment on column public.reviews.structured_scores is 'MT-specific review dimensions such as real capacity, bathroom usability and organizer difficulty';
