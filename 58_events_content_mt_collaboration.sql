-- moTF launch content control tower, hosted events and read-only My MT companions.

create table if not exists public.homepage_cards (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  subtitle text,
  image_url text not null,
  link_url text,
  link_label text,
  placement text not null default 'card_news' check (placement in ('hero','card_news','promotion')),
  sort_order integer not null default 100,
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.popup_banners (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  image_url text,
  link_url text,
  link_label text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  audience text not null default 'all' check (audience in ('all','guest','member','owner')),
  dismiss_days integer not null default 1 check (dismiss_days between 0 and 365),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.platform_events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  short_description text not null,
  description text,
  poster_url text not null,
  gallery_urls text[] not null default '{}',
  venue_name text,
  venue_address text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  application_opens_at timestamptz not null,
  application_closes_at timestamptz not null,
  price_per_person integer not null default 0 check (price_per_person >= 0),
  capacity integer not null check (capacity > 0),
  application_count integer not null default 0 check (application_count >= 0),
  google_form_url text,
  timeline jsonb not null default '[]'::jsonb,
  highlights text[] not null default '{}',
  content_sections jsonb not null default '[]'::jsonb,
  status text not null default 'scheduled' check (status in ('draft','scheduled','open','closed','completed','cancelled')),
  is_featured boolean not null default false,
  sort_order integer not null default 100,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (application_closes_at > application_opens_at)
);

create table if not exists public.recreation_activities (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  summary text not null,
  people_min integer,
  people_max integer,
  spaces text[] not null default '{}',
  play_type text not null check (play_type in ('icebreak','team','solo')),
  duration_minutes integer,
  materials text[] not null default '{}',
  instructions text,
  script_example text,
  media_urls text[] not null default '{}',
  source_submission_id uuid references public.recreation_submissions(id) on delete set null,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references public.profiles(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

do $$ begin
  if not exists(select 1 from pg_trigger where tgname='homepage_cards_set_updated_at') then
    create trigger homepage_cards_set_updated_at before update on public.homepage_cards for each row execute procedure public.set_updated_at();
  end if;
  if not exists(select 1 from pg_trigger where tgname='popup_banners_set_updated_at') then
    create trigger popup_banners_set_updated_at before update on public.popup_banners for each row execute procedure public.set_updated_at();
  end if;
  if not exists(select 1 from pg_trigger where tgname='platform_events_set_updated_at') then
    create trigger platform_events_set_updated_at before update on public.platform_events for each row execute procedure public.set_updated_at();
  end if;
  if not exists(select 1 from pg_trigger where tgname='recreation_activities_set_updated_at') then
    create trigger recreation_activities_set_updated_at before update on public.recreation_activities for each row execute procedure public.set_updated_at();
  end if;
end $$;

alter table public.homepage_cards enable row level security;
alter table public.popup_banners enable row level security;
alter table public.platform_events enable row level security;
alter table public.recreation_activities enable row level security;
alter table public.admin_audit_logs enable row level security;

drop policy if exists "homepage_cards_public_read" on public.homepage_cards;
create policy "homepage_cards_public_read" on public.homepage_cards for select to anon, authenticated
using ((is_active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())) or public.is_admin());
drop policy if exists "homepage_cards_admin_all" on public.homepage_cards;
create policy "homepage_cards_admin_all" on public.homepage_cards for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "popup_banners_public_read" on public.popup_banners;
create policy "popup_banners_public_read" on public.popup_banners for select to anon, authenticated
using ((is_active and starts_at<=now() and ends_at>now()) or public.is_admin());
drop policy if exists "popup_banners_admin_all" on public.popup_banners;
create policy "popup_banners_admin_all" on public.popup_banners for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "platform_events_public_read" on public.platform_events;
drop policy if exists "platform_events_admin_all" on public.platform_events;
create policy "platform_events_admin_all" on public.platform_events for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "recreation_activities_public_read" on public.recreation_activities;
create policy "recreation_activities_public_read" on public.recreation_activities for select to anon, authenticated
using (is_active or public.is_admin());
drop policy if exists "recreation_activities_admin_all" on public.recreation_activities;
create policy "recreation_activities_admin_all" on public.recreation_activities for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin_audit_logs_admin_read" on public.admin_audit_logs;
create policy "admin_audit_logs_admin_read" on public.admin_audit_logs for select to authenticated using (public.is_admin());

grant select on public.homepage_cards, public.popup_banners, public.recreation_activities to anon, authenticated;
revoke all on public.platform_events from anon;
grant select on public.platform_events to authenticated;
grant insert, update, delete on public.homepage_cards, public.popup_banners, public.platform_events, public.recreation_activities to authenticated;
grant select on public.admin_audit_logs to authenticated;

create or replace function public.platform_event_effective_status(target_event public.platform_events)
returns text language sql stable set search_path = '' as $$
  select case
    when target_event.status in ('draft','cancelled','completed') then target_event.status
    when now()>=target_event.ends_at then 'completed'
    when target_event.status='closed' or now()>=target_event.application_closes_at or target_event.application_count>=target_event.capacity then 'closed'
    when now()>=target_event.application_opens_at then 'open'
    else 'scheduled'
  end;
$$;

create or replace function public.get_public_platform_events()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
    (to_jsonb(e) - 'google_form_url') || jsonb_build_object(
      'effective_status', public.platform_event_effective_status(e),
      'google_form_url', case
        when public.platform_event_effective_status(e)='open' then e.google_form_url
        else null
      end
    ) order by e.sort_order,e.starts_at
  ), '[]'::jsonb)
  from public.platform_events e
  where e.status not in ('draft','cancelled');
$$;
revoke all on function public.get_public_platform_events() from public;
grant execute on function public.get_public_platform_events() to anon,authenticated;

-- Cashback is awarded only when a paid transaction becomes completed.
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
  if exists(select 1 from public.point_ledger where user_id=new.customer_id and source_type='cashback_'||source_kind and source_id=new.id and entry_type='earn') then return new; end if;
  insert into public.point_accounts(user_id) values(new.customer_id) on conflict do nothing;
  update public.point_accounts set balance=balance+reward,lifetime_earned=lifetime_earned+reward,updated_at=now()
  where user_id=new.customer_id returning balance into current_balance;
  insert into public.point_ledger(user_id,amount,balance_after,entry_type,reason,source_type,source_id,expires_at)
  values(new.customer_id,reward,current_balance,'earn',campaign.name,'cashback_'||source_kind,new.id,now()+interval '1 year');
  return new;
end;
$$;
drop trigger if exists reservation_completion_cashback on public.reservations;
create trigger reservation_completion_cashback after insert or update of status on public.reservations
for each row execute function public.grant_completion_cashback();
drop trigger if exists market_completion_cashback on public.market_orders;
create trigger market_completion_cashback after insert or update of status on public.market_orders
for each row execute function public.grant_completion_cashback();

-- My MT companions can view, while only the project owner/admin can change data.
create table if not exists public.mt_project_members (
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  member_role text not null default 'viewer' check (member_role in ('owner','viewer')),
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key(project_id,user_id)
);

insert into public.mt_project_members(project_id,user_id,member_role)
select id,owner_id,'owner' from public.mt_projects on conflict(project_id,user_id) do update set member_role='owner';

create or replace function public.add_mt_owner_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.mt_project_members(project_id,user_id,member_role) values(new.id,new.owner_id,'owner') on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists mt_project_add_owner_member on public.mt_projects;
create trigger mt_project_add_owner_member after insert on public.mt_projects for each row execute function public.add_mt_owner_member();

create table if not exists public.mt_project_invites (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  invite_code text not null unique,
  created_by uuid not null references public.profiles(id) on delete cascade,
  max_uses integer not null default 10 check (max_uses between 1 and 100),
  use_count integer not null default 0 check (use_count>=0),
  expires_at timestamptz not null default (now()+interval '7 days'),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.can_view_mt_project(target_project_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin() or exists(select 1 from public.mt_project_members m where m.project_id=target_project_id and m.user_id=auth.uid());
$$;
create or replace function public.can_edit_mt_project(target_project_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin() or exists(select 1 from public.mt_projects p where p.id=target_project_id and p.owner_id=auth.uid());
$$;
revoke all on function public.can_view_mt_project(uuid) from public;
revoke all on function public.can_edit_mt_project(uuid) from public;
grant execute on function public.can_view_mt_project(uuid), public.can_edit_mt_project(uuid) to authenticated;

create or replace function public.create_mt_project_invite(target_project_id uuid, valid_days integer default 7)
returns text language plpgsql security definer set search_path = '' as $$
declare code text;
begin
  if not public.can_edit_mt_project(target_project_id) then raise exception '초대 권한이 없습니다.'; end if;
  loop
    code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
    exit when not exists(select 1 from public.mt_project_invites where invite_code=code);
  end loop;
  insert into public.mt_project_invites(project_id,invite_code,created_by,expires_at)
  values(target_project_id,code,auth.uid(),now()+make_interval(days=>least(greatest(valid_days,1),30)));
  return code;
end;
$$;

create or replace function public.accept_mt_project_invite(target_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare invite public.mt_project_invites%rowtype;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select * into invite from public.mt_project_invites where invite_code=upper(trim(target_code)) for update;
  if invite.id is null or invite.revoked_at is not null or invite.expires_at<=now() or invite.use_count>=invite.max_uses then raise exception '유효하지 않은 초대입니다.'; end if;
  insert into public.mt_project_members(project_id,user_id,member_role,invited_by)
  values(invite.project_id,auth.uid(),'viewer',invite.created_by) on conflict(project_id,user_id) do nothing;
  if found then update public.mt_project_invites set use_count=use_count+1 where id=invite.id; end if;
  return invite.project_id;
end;
$$;
revoke all on function public.create_mt_project_invite(uuid,integer) from public;
revoke all on function public.accept_mt_project_invite(text) from public;
grant execute on function public.create_mt_project_invite(uuid,integer), public.accept_mt_project_invite(text) to authenticated;

alter table public.mt_project_members enable row level security;
alter table public.mt_project_invites enable row level security;
drop policy if exists "mt_members_project_read" on public.mt_project_members;
create policy "mt_members_project_read" on public.mt_project_members for select to authenticated using (public.can_view_mt_project(project_id));
drop policy if exists "mt_invites_owner_read" on public.mt_project_invites;
create policy "mt_invites_owner_read" on public.mt_project_invites for select to authenticated using (public.can_edit_mt_project(project_id));
grant select on public.mt_project_members, public.mt_project_invites to authenticated;

drop policy if exists "mt_projects_owner_all" on public.mt_projects;
drop policy if exists "mt_projects_member_read" on public.mt_projects;
create policy "mt_projects_member_read" on public.mt_projects for select to authenticated using (public.can_view_mt_project(id));
drop policy if exists "mt_projects_owner_write" on public.mt_projects;
create policy "mt_projects_owner_write" on public.mt_projects for all to authenticated using (public.can_edit_mt_project(id)) with check (owner_id=auth.uid() or public.is_admin());

drop policy if exists "mt_candidates_owner_all" on public.mt_project_candidates;
drop policy if exists "mt_candidates_member_read" on public.mt_project_candidates;
create policy "mt_candidates_member_read" on public.mt_project_candidates for select to authenticated using (public.can_view_mt_project(project_id));
drop policy if exists "mt_candidates_owner_write" on public.mt_project_candidates;
create policy "mt_candidates_owner_write" on public.mt_project_candidates for all to authenticated using (public.can_edit_mt_project(project_id)) with check (public.can_edit_mt_project(project_id));

drop policy if exists "mt_items_owner_all" on public.mt_project_items;
drop policy if exists "mt_items_member_read" on public.mt_project_items;
create policy "mt_items_member_read" on public.mt_project_items for select to authenticated using (public.can_view_mt_project(project_id));
drop policy if exists "mt_items_owner_write" on public.mt_project_items;
create policy "mt_items_owner_write" on public.mt_project_items for all to authenticated using (public.can_edit_mt_project(project_id)) with check (public.can_edit_mt_project(project_id));

drop policy if exists "mt_itinerary_owner_all" on public.mt_itinerary_items;
drop policy if exists "mt_itinerary_member_read" on public.mt_itinerary_items;
create policy "mt_itinerary_member_read" on public.mt_itinerary_items for select to authenticated using (public.can_view_mt_project(project_id));
drop policy if exists "mt_itinerary_owner_write" on public.mt_itinerary_items;
create policy "mt_itinerary_owner_write" on public.mt_itinerary_items for all to authenticated using (public.can_edit_mt_project(project_id)) with check (public.can_edit_mt_project(project_id));

drop policy if exists "mt_notices_owner_all" on public.mt_notices;
drop policy if exists "mt_notices_member_read" on public.mt_notices;
create policy "mt_notices_member_read" on public.mt_notices for select to authenticated using (public.can_view_mt_project(project_id));
drop policy if exists "mt_notices_owner_write" on public.mt_notices;
create policy "mt_notices_owner_write" on public.mt_notices for all to authenticated using (public.can_edit_mt_project(project_id)) with check (public.can_edit_mt_project(project_id));

create table if not exists public.mt_polls (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.mt_projects(id) on delete cascade,
  title text not null,
  poll_type text not null default 'general' check (poll_type in ('general','stay','room','penalty')),
  closes_at timestamptz,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.mt_poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.mt_polls(id) on delete cascade,
  label text not null,
  reference_id uuid,
  sort_order integer not null default 0
);
create table if not exists public.mt_poll_votes (
  poll_id uuid not null references public.mt_polls(id) on delete cascade,
  option_id uuid not null references public.mt_poll_options(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(poll_id,user_id)
);
alter table public.mt_polls enable row level security;
alter table public.mt_poll_options enable row level security;
alter table public.mt_poll_votes enable row level security;
create policy "mt_polls_member_read" on public.mt_polls for select to authenticated using (public.can_view_mt_project(project_id));
create policy "mt_polls_owner_write" on public.mt_polls for all to authenticated using (public.can_edit_mt_project(project_id)) with check (public.can_edit_mt_project(project_id));
create policy "mt_poll_options_member_read" on public.mt_poll_options for select to authenticated using (exists(select 1 from public.mt_polls p where p.id=poll_id and public.can_view_mt_project(p.project_id)));
create policy "mt_poll_options_owner_write" on public.mt_poll_options for all to authenticated using (exists(select 1 from public.mt_polls p where p.id=poll_id and public.can_edit_mt_project(p.project_id))) with check (exists(select 1 from public.mt_polls p where p.id=poll_id and public.can_edit_mt_project(p.project_id)));
create policy "mt_poll_votes_member_all" on public.mt_poll_votes for all to authenticated using (user_id=auth.uid() and exists(select 1 from public.mt_polls p where p.id=poll_id and public.can_view_mt_project(p.project_id))) with check (user_id=auth.uid() and exists(select 1 from public.mt_polls p where p.id=poll_id and public.can_view_mt_project(p.project_id)));
grant select,insert,update,delete on public.mt_polls,public.mt_poll_options,public.mt_poll_votes to authenticated;

comment on table public.platform_events is 'Admin-scheduled moTF hosted events with time-gated Google Form applications';
comment on function public.get_public_platform_events() is 'Public event feed that never exposes the application URL before opening time';
comment on table public.mt_project_members is 'Invited companions are view-only; project owner remains the only editor';
