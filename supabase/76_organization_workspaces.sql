-- Organization workspaces: personal logins, accepted members, explicit representative handover.
begin;
create table if not exists public.organizations (
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 2 and 80),
 affiliation text, representative_id uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.organization_members (
 organization_id uuid not null references public.organizations(id),
 user_id uuid not null references public.profiles(id),
 role text not null check(role in ('representative','member')),
 status text not null check(status in ('pending','active','removed','rejected')),
 joined_at timestamptz not null default now(), primary key(organization_id,user_id)
);
create unique index if not exists organization_one_representative
 on public.organization_members(organization_id) where role='representative' and status='active';
create table if not exists public.organization_invites (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 token text not null unique, created_by uuid not null references public.profiles(id),
 accepted_by uuid references public.profiles(id), expires_at timestamptz not null default now()+interval '7 days',
 revoked_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.organization_transfers (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 requested_by uuid not null references public.profiles(id), recipient_id uuid not null references public.profiles(id),
 status text not null default 'requested' check(status in ('requested','accepted','confirmed','cancelled')),
 expires_at timestamptz not null default now()+interval '7 days', created_at timestamptz not null default now()
);
create unique index if not exists organization_one_open_transfer on public.organization_transfers(organization_id)
 where status in ('requested','accepted');
create table if not exists public.organization_audit (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 actor_id uuid references public.profiles(id), action text not null, subject_id uuid,
 details jsonb not null default '{}', created_at timestamptz not null default now()
);
create table if not exists public.organization_point_accounts (
 organization_id uuid primary key references public.organizations(id), balance integer not null default 0 check(balance>=0),
 lifetime_earned integer not null default 0, lifetime_used integer not null default 0,
 updated_at timestamptz not null default now()
);
create table if not exists public.organization_point_ledger (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 actor_id uuid references public.profiles(id), amount integer not null check(amount<>0), balance_after integer not null check(balance_after>=0),
 entry_type text not null check(entry_type in ('earn','use','refund','expire','admin_adjust')),
 reason text not null, source_type text, source_id uuid, created_at timestamptz not null default now()
);
create unique index if not exists organization_point_source_unique on public.organization_point_ledger(organization_id,source_type,source_id,entry_type)
 where source_id is not null;

create or replace function public.is_organization_member(target_id uuid, target_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_members m join public.profiles p on p.id=m.user_id
 where m.organization_id=target_id and m.user_id=target_user and m.status='active' and p.status='approved');
$$;
create or replace function public.is_organization_representative(target_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organizations o where o.id=target_id and o.representative_id=auth.uid())
 and public.is_organization_member(target_id);
$$;
revoke all on function public.is_organization_member(uuid,uuid), public.is_organization_representative(uuid) from public;
grant execute on function public.is_organization_member(uuid,uuid), public.is_organization_representative(uuid) to authenticated,service_role;

do $$ declare t text; begin
 foreach t in array array['organizations','organization_members','organization_invites','organization_transfers','organization_audit','organization_point_accounts','organization_point_ledger'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from anon,authenticated',t);
 execute format('grant select,insert,update,delete on public.%I to service_role',t);
 end loop;
end $$;

create or replace function public.manage_organization(action text, payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare oid uuid; target uuid; iid uuid; invite public.organization_invites%rowtype;
 transfer public.organization_transfers%rowtype; org public.organizations%rowtype; code text; changed integer;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '로그인이 필요합니다.'; end if;
 if action='create' then
   insert into public.organizations(name,affiliation,representative_id)
   values(trim(payload->>'name'),nullif(trim(payload->>'affiliation'),''),auth.uid()) returning id into oid;
   insert into public.organization_members values(oid,auth.uid(),'representative','active',now());
   insert into public.organization_point_accounts(organization_id) values(oid);
 elsif action='accept_invite' then
   select * into invite from public.organization_invites where token=payload->>'token' for update;
   if invite.id is null or invite.revoked_at is not null or invite.expires_at<=now() then raise exception '만료되었거나 취소된 초대입니다.'; end if;
   oid:=invite.organization_id;
   if invite.accepted_by is not null then
     if invite.accepted_by=auth.uid() then return jsonb_build_object('organization_id',oid); end if;
     raise exception '이미 사용된 초대입니다.';
   end if;
   if public.is_organization_member(oid) then raise exception '이미 참여 중인 단체입니다.'; end if;
   insert into public.organization_members values(oid,auth.uid(),'member','pending',now())
   on conflict(organization_id,user_id) do update set role='member',status='pending',joined_at=now();
   update public.organization_invites set accepted_by=auth.uid() where id=invite.id;
 else
   oid:=(payload->>'organization_id')::uuid;
   select * into org from public.organizations where id=oid for update;
   if org.id is null then raise exception '단체를 찾지 못했습니다.'; end if;
   target:=nullif(payload->>'user_id','')::uuid;
   if action='handoff_accept' then
     select * into transfer from public.organization_transfers where id=(payload->>'transfer_id')::uuid
       and organization_id=oid and recipient_id=auth.uid() and status='requested' and expires_at>now() for update;
     if transfer.id is null or not public.is_organization_member(oid) then raise exception '인계 요청을 찾지 못했습니다.'; end if;
     if not exists(select 1 from public.profiles where id=auth.uid() and identity_verified_at is not null) then raise exception '대표 인계를 수락하려면 본인확인을 완료해주세요.'; end if;
     update public.organization_transfers set status='accepted' where id=transfer.id;
   elsif action='leave' then
     if not public.is_organization_member(oid) then raise exception '단체 접근 권한이 없습니다.'; end if;
     if public.is_organization_representative(oid) then raise exception '대표 담당자는 먼저 후임에게 인계해주세요.'; end if;
     update public.organization_members set status='removed' where organization_id=oid and user_id=auth.uid() and status='active';
   else
     if not public.is_organization_representative(oid) and not (action='admin_handoff' and public.is_admin()) then raise exception '대표 담당자만 처리할 수 있습니다.'; end if;
     case action
     when 'rename' then update public.organizations set name=trim(payload->>'name'),affiliation=nullif(trim(payload->>'affiliation'),'') where id=oid;
     when 'invite' then
       code:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
       insert into public.organization_invites(organization_id,token,created_by) values(oid,code,auth.uid()) returning id into iid;
     when 'revoke_invite' then update public.organization_invites set revoked_at=now() where id=(payload->>'invite_id')::uuid and organization_id=oid;
     when 'approve' then
       update public.organization_members set status='active' where organization_id=oid and user_id=target and status='pending';
       get diagnostics changed=row_count; if changed=0 then raise exception '승인 대기 담당자를 찾지 못했습니다.'; end if;
     when 'reject' then update public.organization_members set status='rejected' where organization_id=oid and user_id=target and status='pending';
     when 'remove' then
       if target=org.representative_id then raise exception '대표 담당자는 인계 후 해제해주세요.'; end if;
       update public.organization_members set status='removed' where organization_id=oid and user_id=target;
     when 'handoff_request' then
       if target=auth.uid() or not public.is_organization_member(oid,target) then raise exception '활성 담당자를 후임으로 선택해주세요.'; end if;
       update public.organization_transfers set status='cancelled' where organization_id=oid and status in ('requested','accepted') and expires_at<=now();
       insert into public.organization_transfers(organization_id,requested_by,recipient_id) values(oid,auth.uid(),target);
     when 'handoff_cancel' then update public.organization_transfers set status='cancelled' where organization_id=oid and status in ('requested','accepted');
     when 'handoff_confirm' then
       select * into transfer from public.organization_transfers where id=(payload->>'transfer_id')::uuid and organization_id=oid
         and requested_by=auth.uid() and status='accepted' and expires_at>now() for update;
       if transfer.id is null or not public.is_organization_member(oid,transfer.recipient_id) then raise exception '후임의 수락이 필요합니다.'; end if;
       target:=transfer.recipient_id;
       update public.organization_members set role='member' where organization_id=oid and user_id=org.representative_id;
       update public.organization_members set role='representative' where organization_id=oid and user_id=target;
       update public.organizations set representative_id=target where id=oid;
       update public.organization_transfers set status='confirmed' where id=transfer.id;
       if coalesce((payload->>'remove_previous')::boolean,false) then
         update public.organization_members set status='removed' where organization_id=oid and user_id=auth.uid();
       end if;
     when 'admin_handoff' then
       if length(coalesce(trim(payload->>'reason'),''))<6 or not public.is_organization_member(oid,target)
         or not exists(select 1 from public.profiles where id=target and identity_verified_at is not null)
       then raise exception '확인 사유와 본인확인된 후임 담당자가 필요합니다.'; end if;
       update public.organization_members set role='member' where organization_id=oid and role='representative';
       update public.organization_members set role='representative' where organization_id=oid and user_id=target;
       update public.organizations set representative_id=target where id=oid;
       update public.organization_transfers set status='cancelled' where organization_id=oid and status in ('requested','accepted');
     else raise exception '지원하지 않는 단체 작업입니다.';
     end case;
   end if;
 end if;
 insert into public.organization_audit(organization_id,actor_id,action,subject_id,details)
 values(oid,auth.uid(),action,target,jsonb_build_object('reason',payload->>'reason'));
 return jsonb_build_object('organization_id',oid,'token',code,'invite_id',iid);
end;
$$;
revoke all on function public.manage_organization(text,jsonb) from public;
grant execute on function public.manage_organization(text,jsonb) to authenticated;

create or replace function public.organization_dashboard(target_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 if target_id is not null and not public.is_organization_member(target_id) then raise exception '단체 접근 권한이 없습니다.'; end if;
 return jsonb_build_object(
 'organizations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('member_role',m.role) order by o.created_at)
 from public.organizations o join public.organization_members m on m.organization_id=o.id
 where m.user_id=auth.uid() and m.status='active' and public.is_organization_member(o.id)),'[]'::jsonb),
 'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',m.role,'status',m.status,
 'name',p.full_name,'phone',p.phone,'identity_verified',p.identity_verified_at is not null) order by m.joined_at)
 from public.organization_members m join public.profiles p on p.id=m.user_id where m.organization_id=target_id
 and (m.status='active' or public.is_organization_representative(target_id))),'[]'::jsonb),
 'invites',coalesce((select jsonb_agg(to_jsonb(i)-'token' order by i.created_at desc) from public.organization_invites i
 where i.organization_id=target_id and public.is_organization_representative(target_id) and i.expires_at>now() and i.revoked_at is null),'[]'::jsonb),
 'transfers',coalesce((select jsonb_agg(to_jsonb(t)) from public.organization_transfers t where t.organization_id=target_id
 and t.status in ('requested','accepted') and t.expires_at>now()),'[]'::jsonb),
 'wallet',(select to_jsonb(w) from public.organization_point_accounts w where w.organization_id=target_id),
 'ledger',coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from
 (select * from public.organization_point_ledger where organization_id=target_id order by created_at desc limit 100) l),'[]'::jsonb));
end;
$$;
revoke all on function public.organization_dashboard(uuid) from public;
grant execute on function public.organization_dashboard(uuid) to authenticated;

alter table public.mt_projects add column if not exists organization_id uuid references public.organizations(id);
create or replace function public.can_view_mt_project(target_project_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select public.is_admin() or exists(select 1 from public.mt_projects p where p.id=target_project_id and
 (case when p.organization_id is not null then public.is_organization_member(p.organization_id)
 else p.owner_id=auth.uid() or exists(select 1 from public.mt_project_members m where m.project_id=p.id and m.user_id=auth.uid()) end));
$$;
create or replace function public.can_edit_mt_project(target_project_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select public.is_admin() or exists(select 1 from public.mt_projects p where p.id=target_project_id and
 case when p.organization_id is not null then public.is_organization_member(p.organization_id) else p.owner_id=auth.uid() end);
$$;
drop policy if exists mt_projects_owner_write on public.mt_projects;
drop policy if exists mt_projects_owner_all on public.mt_projects;
drop policy if exists mt_projects_member_read on public.mt_projects;
create policy mt_projects_member_read on public.mt_projects for select to authenticated using (
 public.is_admin() or case when organization_id is not null then public.is_organization_member(organization_id)
 else owner_id=auth.uid() or exists(select 1 from public.mt_project_members m where m.project_id=mt_projects.id and m.user_id=auth.uid()) end
);
drop policy if exists organization_projects_insert on public.mt_projects;
drop policy if exists organization_projects_update on public.mt_projects;
drop policy if exists organization_projects_delete on public.mt_projects;
create policy organization_projects_insert on public.mt_projects for insert to authenticated
 with check(owner_id=auth.uid() and (organization_id is null or public.is_organization_member(organization_id)));
create policy organization_projects_update on public.mt_projects for update to authenticated
 using(public.can_edit_mt_project(id)) with check(public.can_edit_mt_project(id));
create policy organization_projects_delete on public.mt_projects for delete to authenticated
 using(public.can_edit_mt_project(id));
create or replace function public.freeze_mt_project_account()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.owner_id is distinct from old.owner_id or new.organization_id is distinct from old.organization_id then
 raise exception 'MT를 만든 계정과 소속 단체는 변경할 수 없습니다.'; end if;
 return new;
end;
$$;
drop trigger if exists freeze_mt_project_account on public.mt_projects;
create trigger freeze_mt_project_account before update on public.mt_projects for each row execute function public.freeze_mt_project_account();

create or replace function public.guard_organization_withdrawal()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.withdrawal_processed_at is not null and old.withdrawal_processed_at is null then
  if exists(select 1 from public.organizations where representative_id=old.id) then raise exception '단체 대표 담당자는 먼저 인계를 완료해주세요.'; end if;
  update public.organization_members set status='removed' where user_id=old.id;
 end if;
 return new;
end;
$$;
drop trigger if exists guard_organization_withdrawal on public.profiles;
create trigger guard_organization_withdrawal before update of withdrawal_processed_at on public.profiles
 for each row execute function public.guard_organization_withdrawal();
create or replace function public.save_mt_room_candidate(
  target_project_id uuid,
  target_business_id uuid,
  target_offering_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_project public.mt_projects%rowtype;
  target_room public.offerings%rowtype;
  candidate_id uuid;
  base_amount integer;
  extra_people integer;
  extra_people_amount integer;
begin
  if auth.uid() is null then
    raise exception 'Login is required.';
  end if;

  select * into target_project
  from public.mt_projects
  where id = target_project_id
    and public.can_edit_mt_project(id);

  if target_project.id is null then
    raise exception 'My MT project was not found.';
  end if;

  select * into target_room
  from public.offerings
  where id = target_offering_id
    and business_id = target_business_id
    and is_active;

  if target_room.id is null then
    raise exception 'The selected room is not available.';
  end if;

  if not public.stay_range_is_available(
    target_room.id,
    target_project.starts_on,
    target_project.ends_on
  ) then
    raise exception 'The selected room is already booked for the My MT dates.';
  end if;

  if not exists (
    select 1 from public.mt_project_candidates c
    where c.project_id = target_project.id and c.offering_id = target_room.id
  ) and (
    select count(*) from public.mt_project_candidates c
    where c.project_id = target_project.id
  ) >= 3 then
    raise exception 'Up to three room candidates can be saved per My MT project.';
  end if;

  base_amount := public.calculate_stay_base_amount(
    target_room.id,
    target_project.starts_on,
    target_project.ends_on
  );
  extra_people := greatest(
    target_project.guest_count - coalesce(target_room.base_people, target_room.min_people, 0),
    0
  );
  extra_people_amount := extra_people * coalesce(target_room.extra_person_fee, 0);

  insert into public.mt_project_candidates (
    project_id, business_id, offering_id, estimated_cost, sort_order
  ) values (
    target_project.id,
    target_business_id,
    target_room.id,
    jsonb_build_object(
      'room_total', base_amount,
      'confirmed', base_amount,
      'extra_people', extra_people,
      'extra_person_total', extra_people_amount,
      'optional', 0,
      'on_site', extra_people_amount,
      'total', base_amount + extra_people_amount,
      'room_names', jsonb_build_array(target_room.name)
    ),
    (extract(epoch from clock_timestamp())::bigint % 1000000)::integer
  )
  on conflict (project_id, offering_id) do update
  set
    business_id = excluded.business_id,
    estimated_cost = excluded.estimated_cost,
    sort_order = excluded.sort_order
  returning id into candidate_id;

  return candidate_id;
end;
$$;
commit;
