-- Local-design community: gatherings and consent-only completed MT records.
begin;

create table if not exists public.community_gatherings (
  post_id uuid primary key references public.community_posts(id) on delete cascade,
  gathering_type text not null check (gathering_type in ('인원 모집','합동 MT','취향 MT')),
  starts_on date not null,
  ends_on date not null,
  region text not null check (char_length(region) between 1 and 40),
  seats_label text not null check (char_length(seats_label) between 1 and 40),
  budget_per_person integer not null default 0 check (budget_per_person between 0 and 10000000),
  status text not null default 'open' check (status in ('open','closed')),
  check (ends_on > starts_on)
);
alter table public.community_gatherings enable row level security;
revoke all on public.community_gatherings from public,anon,authenticated;
drop policy if exists gathering_author_read on public.community_gatherings;
create policy gathering_author_read on public.community_gatherings for select to authenticated
using (exists(select 1 from public.community_posts p where p.id=post_id and (p.author_id=auth.uid() or public.is_admin())));
grant select on public.community_gatherings to authenticated;

create or replace function public.save_mt_gathering(payload jsonb, target_post_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare result_id uuid; begin
  if auth.uid() is null then raise exception '로그인 후 모집 글을 작성해주세요.'; end if;
  if char_length(trim(coalesce(payload->>'title',''))) not between 2 and 100
    or char_length(trim(coalesce(payload->>'body',''))) not between 1 and 5000
    or char_length(trim(coalesce(payload->>'alias',''))) not between 1 and 30 then
    raise exception '제목, 작성자 별명과 내용을 확인해주세요.';
  end if;
  if target_post_id is not null then
    select id into result_id from public.community_posts
      where id=target_post_id and board_key='together' and (author_id=auth.uid() or public.is_admin()) for update;
    if result_id is null then raise exception '수정 권한이 없습니다.'; end if;
    update public.community_posts set title=trim(payload->>'title'),body=trim(payload->>'body'),author_name=trim(payload->>'alias') where id=result_id;
  else
    insert into public.community_posts(author_id,author_name,title,body,board_key)
    values(auth.uid(),trim(payload->>'alias'),trim(payload->>'title'),trim(payload->>'body'),'together') returning id into result_id;
  end if;
  insert into public.community_gatherings(post_id,gathering_type,starts_on,ends_on,region,seats_label,budget_per_person,status)
  values(result_id,payload->>'type',(payload->>'start')::date,(payload->>'end')::date,trim(payload->>'region'),trim(payload->>'seats'),(payload->>'budget')::integer,coalesce(payload->>'status','open'))
  on conflict(post_id) do update set gathering_type=excluded.gathering_type,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    region=excluded.region,seats_label=excluded.seats_label,budget_per_person=excluded.budget_per_person,status=excluded.status;
  return result_id;
end $$;
revoke all on function public.save_mt_gathering(jsonb,uuid) from public,anon;
grant execute on function public.save_mt_gathering(jsonb,uuid) to authenticated;

create or replace function public.get_public_mt_gatherings(target_post_id uuid default null, result_limit integer default 100)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_data order by created_at desc),'[]'::jsonb) from (
   select p.created_at,jsonb_build_object('id',p.id,'title',p.title,'body',p.body,'alias',p.author_name,
    'created_at',p.created_at,'is_author',p.author_id=auth.uid(),'type',g.gathering_type,'start',g.starts_on,'end',g.ends_on,
    'region',g.region,'seats',g.seats_label,'budget',g.budget_per_person,'status',g.status) row_data
   from public.community_gatherings g join public.community_posts p on p.id=g.post_id
   where not p.is_hidden and (target_post_id is null or p.id=target_post_id)
   order by p.created_at desc limit greatest(1,least(coalesce(result_limit,100),200))
 ) rows;
$$;
revoke all on function public.get_public_mt_gatherings(uuid,integer) from public;
grant execute on function public.get_public_mt_gatherings(uuid,integer) to anon,authenticated;

create table if not exists public.mt_record_shares (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null unique references public.mt_projects(id) on delete cascade,
  published_by uuid not null references public.profiles(id),
  alias text not null check (char_length(trim(alias)) between 1 and 30),
  title text not null check (char_length(trim(title)) between 2 and 100),
  memo text not null default '' check (char_length(memo)<=2000),
  fields text[] not null default '{}' check (fields <@ array['stay','shopping','games']::text[]),
  consented_at timestamptz not null default now(),
  is_public boolean not null default true,
  moderation_hidden boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.mt_record_shares enable row level security;
-- Supabase projects may automatically grant all privileges on newly created tables.
revoke all on public.mt_record_shares from public,anon,authenticated;
drop policy if exists mt_record_editors_read on public.mt_record_shares;
create policy mt_record_editors_read on public.mt_record_shares for select to authenticated using(public.can_edit_mt_project(project_id));
drop policy if exists mt_record_editors_insert on public.mt_record_shares;
create policy mt_record_editors_insert on public.mt_record_shares for insert to authenticated with check(
 public.can_edit_mt_project(project_id) and published_by=auth.uid()
 and exists(select 1 from public.mt_projects p where p.id=project_id and p.status='completed'));
drop policy if exists mt_record_editors_update on public.mt_record_shares;
create policy mt_record_editors_update on public.mt_record_shares for update to authenticated using(public.can_edit_mt_project(project_id)) with check(
 public.can_edit_mt_project(project_id) and published_by=auth.uid()
 and (not is_public or exists(select 1 from public.mt_projects p where p.id=project_id and p.status='completed')));
drop policy if exists mt_record_editors_delete on public.mt_record_shares;
create policy mt_record_editors_delete on public.mt_record_shares for delete to authenticated using(public.can_edit_mt_project(project_id));
grant select,delete on public.mt_record_shares to authenticated;
grant insert(project_id,published_by,alias,title,memo,fields,consented_at,is_public,updated_at),
 update(published_by,alias,title,memo,fields,consented_at,is_public,updated_at) on public.mt_record_shares to authenticated;

create or replace function public.moderate_mt_record(target_record_id uuid, hide_record boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception '운영자 권한이 필요합니다.'; end if;
 update public.mt_record_shares set moderation_hidden=hide_record,updated_at=now() where id=target_record_id;
end $$;
revoke all on function public.moderate_mt_record(uuid,boolean) from public,anon;
grant execute on function public.moderate_mt_record(uuid,boolean) to authenticated;

create or replace function public.get_public_mt_records(target_record_id uuid default null, result_limit integer default 100)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(record order by ends_on desc),'[]'::jsonb) from (
  select p.ends_on,jsonb_build_object(
   'id',s.id,'alias',s.alias,'title',s.title,'memo',s.memo,'people',p.guest_count,'region',p.region,'date',p.ends_on,'budget',p.estimated_budget,
   'lodging',coalesce(cost.lodging,0),'shopping',coalesce(cost.shopping,0),'other',coalesce(cost.other,0),
   'used',coalesce(cost.lodging,0)+coalesce(cost.shopping,0)+coalesce(cost.other,0),
   'stay',case when 'stay'=any(s.fields) then coalesce(cost.stay_name,'선택한 숙소 없음') else '숙소명 비공개' end,
   'products',case when 'shopping'=any(s.fields) then coalesce(cost.products,'[]'::jsonb) else '[]'::jsonb end,
   'games',case when 'games'=any(s.fields) then coalesce(cost.games,'[]'::jsonb) else '[]'::jsonb end
  ) record
  from public.mt_record_shares s join public.mt_projects p on p.id=s.project_id
  left join lateral (
   select sum(i.amount*i.quantity) filter(where i.item_kind='stay') lodging,
    sum(i.amount*i.quantity) filter(where i.item_kind='shopping') shopping,
    sum(i.amount*i.quantity) filter(where i.item_kind not in ('stay','shopping')) other,
    max(i.title) filter(where i.item_kind='stay') stay_name,
    jsonb_agg(jsonb_build_object('title',i.title,'quantity',i.quantity)) filter(where i.item_kind='shopping') products,
    jsonb_agg(i.title) filter(where i.item_kind='activity') games
   from public.mt_project_items i where i.project_id=p.id and i.status<>'cancelled'
  ) cost on true
  where s.is_public and not s.moderation_hidden and p.status='completed'
    and (target_record_id is null or s.id=target_record_id)
  order by p.ends_on desc limit greatest(1,least(coalesce(result_limit,100),200))
 ) rows;
$$;
revoke all on function public.get_public_mt_records(uuid,integer) from public;
grant execute on function public.get_public_mt_records(uuid,integer) to anon,authenticated;

create index if not exists community_gatherings_dates_idx on public.community_gatherings(starts_on,status);
create index if not exists mt_record_shares_public_idx on public.mt_record_shares(is_public) where not moderation_hidden;
notify pgrst,'reload schema';
commit;
