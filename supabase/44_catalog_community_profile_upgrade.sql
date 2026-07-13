-- Catalog filters, detailed listings, community reactions, and richer user profiles.

alter table public.businesses
  add column if not exists station_distance_m integer check (station_distance_m is null or station_distance_m >= 0),
  add column if not exists convenience_distance_m integer check (convenience_distance_m is null or convenience_distance_m >= 0),
  add column if not exists nearby_tags text[] not null default '{}',
  add column if not exists room_count integer not null default 0 check (room_count >= 0),
  add column if not exists bath_count integer not null default 0 check (bath_count >= 0),
  add column if not exists amenity_details jsonb not null default '[]'::jsonb,
  add column if not exists extra_fees jsonb not null default '[]'::jsonb,
  add column if not exists refund_policy jsonb not null default '[
    {"days_before":14,"refund_percent":100,"label":"이용 14일 전까지"},
    {"days_before":7,"refund_percent":50,"label":"이용 7일 전까지"},
    {"days_before":3,"refund_percent":20,"label":"이용 3일 전까지"},
    {"days_before":0,"refund_percent":0,"label":"이후 및 당일"}
  ]'::jsonb,
  add column if not exists recommended_sets jsonb not null default '[]'::jsonb;

alter table public.offerings
  add column if not exists min_people integer check (min_people is null or min_people > 0),
  add column if not exists feature_summary text[] not null default '{}',
  add column if not exists amenity_details jsonb not null default '[]'::jsonb,
  add column if not exists detail_sections jsonb not null default '{}'::jsonb,
  add column if not exists origin text,
  add column if not exists nutrition_info jsonb not null default '{}'::jsonb,
  add column if not exists is_alcohol boolean not null default false,
  add column if not exists stock_quantity integer check (stock_quantity is null or stock_quantity >= 0);

alter table public.profiles
  add column if not exists affiliations jsonb not null default '[]'::jsonb,
  add column if not exists welcome_email_sent_at timestamptz;

alter table public.community_posts
  add column if not exists board_key text not null default 'confession',
  add column if not exists media_urls text[] not null default '{}';

grant update (
  station_distance_m, convenience_distance_m, nearby_tags, room_count, bath_count,
  amenity_details, extra_fees, refund_policy, recommended_sets, updated_at
) on public.businesses to authenticated;

grant select (
  station_distance_m, convenience_distance_m, nearby_tags, room_count, bath_count,
  amenity_details, extra_fees, refund_policy, recommended_sets
) on public.businesses to anon, authenticated;

grant select (
  min_people, feature_summary, amenity_details, detail_sections, origin,
  nutrition_info, is_alcohol, stock_quantity
) on public.offerings to anon, authenticated;

grant update (affiliations, updated_at) on public.profiles to authenticated;

create or replace function public.save_business_offerings(target_business_id uuid, items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.owns_business(target_business_id) and not public.is_admin() then
    raise exception '상품 수정 권한이 없습니다.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception '하나 이상의 객실 또는 상품이 필요합니다.';
  end if;

  delete from public.offerings where business_id = target_business_id;
  insert into public.offerings (
    business_id, name, description, price, is_active, max_people, min_people, unit,
    category, image_url, sort_order, feature_summary, amenity_details, detail_sections,
    origin, nutrition_info, is_alcohol, stock_quantity
  )
  select target_business_id, nullif(trim(item->>'name'), ''), nullif(trim(item->>'description'), ''),
    greatest(coalesce((item->>'price')::integer, 0), 0), true,
    nullif(item->>'max_people','')::integer, nullif(item->>'min_people','')::integer,
    nullif(trim(item->>'unit'),''), nullif(trim(item->>'category'),''), nullif(trim(item->>'image_url'),''),
    coalesce((item->>'sort_order')::integer,0), coalesce(item->'feature_summary','[]'::jsonb),
    coalesce(item->'amenity_details','[]'::jsonb), coalesce(item->'detail_sections','{}'::jsonb),
    nullif(trim(item->>'origin'),''), coalesce(item->'nutrition_info','{}'::jsonb),
    coalesce((item->>'is_alcohol')::boolean,false), nullif(item->>'stock_quantity','')::integer
  from jsonb_array_elements(items) item;
end;
$$;

revoke all on function public.save_business_offerings(uuid,jsonb) from public;
grant execute on function public.save_business_offerings(uuid,jsonb) to authenticated;

create table if not exists public.community_post_likes (
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  parent_comment_id uuid references public.community_comments(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists community_comments_post_created_idx
  on public.community_comments(post_id, created_at);

create table if not exists public.recreation_submissions (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  people_label text,
  spaces text[] not null default '{}',
  play_type text check (play_type is null or play_type in ('icebreak', 'team', 'solo')),
  instructions text,
  media_urls text[] not null default '{}',
  review_status text not null default 'pending' check (review_status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.community_post_likes enable row level security;
alter table public.community_comments enable row level security;
alter table public.recreation_submissions enable row level security;

create policy "community_likes_read" on public.community_post_likes
for select to authenticated using (true);
create policy "community_likes_own_insert" on public.community_post_likes
for insert to authenticated with check (user_id = auth.uid());
create policy "community_likes_own_delete" on public.community_post_likes
for delete to authenticated using (user_id = auth.uid());

create policy "community_comments_read" on public.community_comments
for select to authenticated using (true);
create policy "community_comments_own_insert" on public.community_comments
for insert to authenticated with check (user_id = auth.uid());
create policy "community_comments_own_update" on public.community_comments
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "community_comments_own_delete" on public.community_comments
for delete to authenticated using (user_id = auth.uid() or public.is_admin());

create policy "recreation_submissions_own_read" on public.recreation_submissions
for select to authenticated using (submitted_by = auth.uid() or public.is_admin());
create policy "recreation_submissions_own_insert" on public.recreation_submissions
for insert to authenticated with check (submitted_by = auth.uid());
create policy "recreation_submissions_admin_update" on public.recreation_submissions
for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, delete on public.community_post_likes to authenticated;
grant select, insert, update, delete on public.community_comments to authenticated;
grant select, insert, update on public.recreation_submissions to authenticated;

create or replace function public.claim_welcome_email()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  update public.profiles
  set welcome_email_sent_at = now(), updated_at = now()
  where id = auth.uid() and welcome_email_sent_at is null;

  return found;
end;
$$;

revoke all on function public.claim_welcome_email() from public;
grant execute on function public.claim_welcome_email() to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('community-media', 'community-media', true, 52428800, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "community_media_public_read" on storage.objects
for select to public using (bucket_id = 'community-media');
create policy "community_media_user_upload" on storage.objects
for insert to authenticated with check (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "community_media_user_delete" on storage.objects
for delete to authenticated using (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text);
