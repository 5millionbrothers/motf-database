-- Personal logins, per-business staff permissions and explicit representative handover.
begin;
alter table public.businesses add column if not exists owner_workspace_created boolean not null default false;
alter table public.businesses add column if not exists workspace_closed_at timestamptz;
create or replace function public.owns_business(target_business_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.businesses where id=target_business_id and owner_id=auth.uid() and workspace_closed_at is null);
$$;
revoke all on function public.owns_business(uuid) from public,anon;
grant execute on function public.owns_business(uuid) to authenticated,service_role;
create table if not exists public.business_members (
 business_id uuid not null references public.businesses(id), user_id uuid not null references public.profiles(id),
 permissions text[] not null default '{}', status text not null default 'active' check(status in ('active','removed')),
 invited_by uuid references public.profiles(id), joined_at timestamptz not null default now(),
 primary key(business_id,user_id),
 check(permissions <@ array['reservations','availability','chat','listing','settlements']::text[])
);
create table if not exists public.business_staff_invitations (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 invited_user_id uuid not null references public.profiles(id), created_by uuid not null references public.profiles(id),
 token_hash text not null unique, permissions text[] not null,
 status text not null default 'pending' check(status in ('pending','accepted','revoked')),
 expires_at timestamptz not null default now()+interval '7 days', created_at timestamptz not null default now(),
 check(permissions <@ array['reservations','availability','chat','listing','settlements']::text[])
);
create table if not exists public.business_ownership_transfers (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 from_user_id uuid not null references public.profiles(id), to_user_id uuid not null references public.profiles(id),
 status text not null default 'requested' check(status in ('requested','accepted','confirmed','cancelled')),
 expires_at timestamptz not null default now()+interval '7 days', created_at timestamptz not null default now(),
 check(from_user_id<>to_user_id)
);
create unique index if not exists business_one_open_transfer on public.business_ownership_transfers(business_id)
 where status in ('requested','accepted');
create table if not exists public.business_transfer_verifications (
 transfer_id uuid primary key references public.business_ownership_transfers(id), user_id uuid not null references public.profiles(id),
 verified_at timestamptz not null, expires_at timestamptz not null, consumed_at timestamptz
);
create table if not exists public.business_workspace_audit (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id),
 actor_id uuid references public.profiles(id), action text not null, subject_id uuid,
 details jsonb not null default '{}', created_at timestamptz not null default now()
);
create index if not exists business_members_user_active on public.business_members(user_id,business_id) where status='active';
create index if not exists business_workspace_audit_business_date on public.business_workspace_audit(business_id,created_at desc);
do $$ declare t text; begin
 foreach t in array array['business_members','business_staff_invitations','business_ownership_transfers','business_transfer_verifications','business_workspace_audit'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update,delete on public.%I to service_role',t);
 end loop;
end $$;

create or replace function public.has_business_permission_for(target_business_id uuid,permission text,target_user_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select permission in ('reservations','availability','chat','listing','settlements') and exists(
 select 1 from public.businesses b join public.profiles p on p.id=target_user_id
 where b.id=target_business_id and b.workspace_closed_at is null and b.approval_status in ('approved','pending','rejected')
 and (p.status='approved' or (p.status='pending' and b.owner_id=p.id and p.role='partner'))
 and (b.owner_id=p.id or (p.status='approved' and b.approval_status='approved' and exists(
 select 1 from public.business_members m where m.business_id=b.id and m.user_id=p.id and m.status='active' and permission=any(m.permissions)))));
$$;
create or replace function public.has_business_permission(target_business_id uuid,permission text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.has_business_permission_for(target_business_id,permission,auth.uid());
$$;
create or replace function public.can_access_business_workspace(target_business_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.businesses b join public.profiles p on p.id=auth.uid()
 where b.id=target_business_id and b.workspace_closed_at is null and p.status in ('approved','pending')
 and (b.owner_id=p.id and p.role='partner' or (p.status='approved' and b.approval_status='approved' and exists(
 select 1 from public.business_members m where m.business_id=b.id and m.user_id=p.id and m.status='active'))));
$$;
revoke all on function public.has_business_permission_for(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.has_business_permission_for(uuid,text,uuid) to service_role;
revoke all on function public.has_business_permission(uuid,text),public.can_access_business_workspace(uuid) from public,anon;
grant execute on function public.has_business_permission(uuid,text),public.can_access_business_workspace(uuid) to authenticated,service_role;

create or replace function public.list_own_business_workspaces()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status in ('approved','pending')) then
 raise exception '로그인이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
 'id',b.id,'business_name',b.business_name,'business_type',b.business_type,'approval_status',b.approval_status,
 'workspace_role',case when b.owner_id=auth.uid() then 'representative' else 'staff' end,
 'permissions',case when b.owner_id=auth.uid() then array['reservations','availability','chat','listing','settlements']::text[] else m.permissions end,
 'can_open',b.approval_status='approved' or (b.owner_id=auth.uid() and (b.import_job_id is not null or b.owner_workspace_created)
 and b.approval_status in ('pending','rejected'))
 ) order by b.created_at,b.id) from public.businesses b left join public.business_members m
 on m.business_id=b.id and m.user_id=auth.uid() and m.status='active'
 where public.can_access_business_workspace(b.id)), '[]'::jsonb);
end;
$$;

create or replace function public.business_workspace_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status in ('approved','pending')) then
 raise exception '로그인이 필요합니다.' using errcode='42501'; end if;
 return jsonb_build_object('workspaces',public.list_own_business_workspaces(),
 'members',coalesce((select jsonb_agg(jsonb_build_object('business_id',m.business_id,'user_id',m.user_id,'full_name',p.full_name,
 'username',p.username,'permissions',m.permissions,'status',m.status) order by m.joined_at)
 from public.business_members m join public.businesses b on b.id=m.business_id join public.profiles p on p.id=m.user_id
 where b.owner_id=auth.uid()),'[]'::jsonb),
 'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'business_id',i.business_id,'business_name',b.business_name,
 'invited_user_id',i.invited_user_id,'invited_username',p.username,'status',i.status,'expires_at',i.expires_at)
 order by i.created_at desc) from public.business_staff_invitations i join public.businesses b on b.id=i.business_id
 join public.profiles p on p.id=i.invited_user_id where i.status='pending' and i.expires_at>now()
 and (b.owner_id=auth.uid() or (i.invited_user_id=auth.uid() and i.created_by=b.owner_id))),'[]'::jsonb),
 'transfers',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('business_name',b.business_name,'to_username',p.username))
 from public.business_ownership_transfers t join public.businesses b on b.id=t.business_id join public.profiles p on p.id=t.to_user_id
 where t.status in ('requested','accepted') and t.expires_at>now() and (b.owner_id=auth.uid() or t.to_user_id=auth.uid())),'[]'::jsonb),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from
 (select a.* from public.business_workspace_audit a join public.businesses b on b.id=a.business_id where b.owner_id=auth.uid()
 order by a.created_at desc limit 100) a),'[]'::jsonb));
end;
$$;
revoke all on function public.business_workspace_dashboard() from public,anon;
grant execute on function public.business_workspace_dashboard() to authenticated;

create or replace function public.record_business_transfer_verification(target_transfer_id uuid,target_user_id uuid,verified_at timestamptz)
returns void language plpgsql security definer set search_path='' as $$
begin
 if verified_at is null or verified_at<now()-interval '15 minutes' or verified_at>now()+interval '1 minute'
 or not exists(select 1 from public.business_ownership_transfers t join public.businesses b on b.id=t.business_id
 join public.business_members m on m.business_id=t.business_id and m.user_id=t.to_user_id and m.status='active'
 join public.profiles p on p.id=t.to_user_id and p.status='approved'
 where t.id=target_transfer_id and t.to_user_id=target_user_id and t.from_user_id=b.owner_id
 and t.status='requested' and t.expires_at>now()) then raise exception '유효한 본인확인과 인계 요청이 필요합니다.'; end if;
 insert into public.business_transfer_verifications values(target_transfer_id,target_user_id,verified_at,now()+interval '15 minutes',null)
 on conflict(transfer_id) do update set user_id=excluded.user_id,verified_at=excluded.verified_at,expires_at=excluded.expires_at,consumed_at=null;
end;
$$;
revoke all on function public.record_business_transfer_verification(uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.record_business_transfer_verification(uuid,uuid,timestamptz) to service_role;

create or replace function public.manage_business_workspace(action text,payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare bid uuid; target uuid; token text; iid uuid; perms text[]; b public.businesses%rowtype;
 invite public.business_staff_invitations%rowtype; transfer public.business_ownership_transfers%rowtype; changed integer;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status in ('approved','pending')) then raise exception '로그인이 필요합니다.'; end if;
 if action='create' then
  if not exists(select 1 from public.profiles where id=auth.uid() and role='partner' and status='approved') then raise exception '대표 계정으로 생성해 주세요.'; end if;
  if length(trim(coalesce(payload->>'business_name',''))) not between 2 and 80 or coalesce(payload->>'business_type','') not in ('stay','market') then raise exception '업장명과 유형을 확인해 주세요.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('business-create:'||auth.uid()::text,0));
  if (select count(*) from public.businesses where owner_id=auth.uid() and approval_status<>'approved')>=10 then raise exception '미완료 업장 초안을 먼저 정리해 주세요.'; end if;
  insert into public.businesses(owner_id,business_name,business_type,representative_name,phone,approval_status,owner_workspace_created)
  select p.id,trim(payload->>'business_name'),payload->>'business_type',coalesce(nullif(p.full_name,''),'확인 필요'),p.phone,'pending',true
  from public.profiles p where p.id=auth.uid() returning id into bid;
 elsif action='accept' then
  select * into invite from public.business_staff_invitations i where (i.id=nullif(payload->>'invitation_id','')::uuid
   or i.token_hash=md5(payload->>'token')) and i.invited_user_id=auth.uid() for update;
  if invite.id is null or invite.status<>'pending' or invite.expires_at<=now() then raise exception '유효한 초대를 찾지 못했습니다.'; end if;
  bid:=invite.business_id; select * into b from public.businesses where id=bid for update;
  if b.owner_id<>invite.created_by or b.approval_status<>'approved' or not exists(select 1 from public.profiles where id=auth.uid() and status='approved') then raise exception '취소되었거나 사용할 수 없는 초대입니다.'; end if;
  insert into public.business_members(business_id,user_id,permissions,status,invited_by) values(bid,auth.uid(),invite.permissions,'active',b.owner_id)
  on conflict(business_id,user_id) do update set permissions=excluded.permissions,status='active',invited_by=excluded.invited_by,joined_at=now();
  update public.business_staff_invitations set status='accepted' where id=invite.id;
  target:=auth.uid();
 elsif action='transfer_accept' then
  select * into transfer from public.business_ownership_transfers where id=(payload->>'transfer_id')::uuid for update;
  bid:=transfer.business_id; select * into b from public.businesses where id=bid for update;
  if transfer.id is null or transfer.status<>'requested' or transfer.expires_at<=now() or transfer.to_user_id<>auth.uid()
   or transfer.from_user_id<>b.owner_id or not public.can_access_business_workspace(bid) then raise exception '유효한 인계 요청이 필요합니다.'; end if;
  update public.business_transfer_verifications set consumed_at=now() where transfer_id=transfer.id and user_id=auth.uid()
   and consumed_at is null and expires_at>now();
  get diagnostics changed=row_count; if changed<>1 then raise exception '새로운 본인확인을 완료한 후 수락해 주세요.'; end if;
  update public.business_ownership_transfers set status='accepted' where id=transfer.id;
  target:=auth.uid();
 else
  if action in ('transfer_confirm','transfer_cancel') then
   select * into transfer from public.business_ownership_transfers where id=(payload->>'transfer_id')::uuid for update;
   bid:=transfer.business_id;
  else bid:=nullif(payload->>'business_id','')::uuid; end if;
  select * into b from public.businesses where id=bid for update;
  if b.id is null or b.owner_id<>auth.uid() or not public.can_access_business_workspace(bid) then raise exception '대표만 처리할 수 있습니다.' using errcode='42501'; end if;
  case action
  when 'invite' then
   if b.approval_status<>'approved' then raise exception '승인된 업장만 직원을 초대할 수 있습니다.'; end if;
   select id into target from public.profiles where lower(username)=lower(trim(payload->>'username')) and status='approved';
   if target is null or target=auth.uid() then raise exception '초대받을 회원 아이디를 확인해 주세요.'; end if;
   if jsonb_typeof(payload->'permissions') is distinct from 'array' then raise exception '권한을 선택해 주세요.'; end if;
   select coalesce(array_agg(distinct x),'{}') into perms from jsonb_array_elements_text(payload->'permissions') x;
   if not(perms<@array['reservations','availability','chat','listing','settlements']::text[]) or cardinality(perms)=0 then raise exception '올바른 직원 권한을 선택해 주세요.'; end if;
   update public.business_staff_invitations set status='revoked' where business_id=bid and invited_user_id=target and status='pending';
   token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
   insert into public.business_staff_invitations(business_id,invited_user_id,created_by,token_hash,permissions)
   values(bid,target,auth.uid(),md5(token),perms) returning id into iid;
  when 'revoke_invite' then
   update public.business_staff_invitations set status='revoked' where id=(payload->>'invitation_id')::uuid and business_id=bid;
  when 'revoke' then
   target:=(payload->>'user_id')::uuid;
   if target=auth.uid() then raise exception '대표는 먼저 소유권을 인계해 주세요.'; end if;
   update public.business_members set status='removed' where business_id=bid and user_id=target;
   update public.business_staff_invitations set status='revoked' where business_id=bid and invited_user_id=target and status='pending';
   update public.business_ownership_transfers set status='cancelled' where business_id=bid and to_user_id=target and status in ('requested','accepted');
  when 'permissions' then
   target:=(payload->>'user_id')::uuid;
   if jsonb_typeof(payload->'permissions') is distinct from 'array' then raise exception '권한 목록이 필요합니다.'; end if;
   select coalesce(array_agg(distinct x),'{}') into perms from jsonb_array_elements_text(payload->'permissions') x;
   if not(perms<@array['reservations','availability','chat','listing','settlements']::text[]) then raise exception '올바른 권한 목록이 필요합니다.'; end if;
   update public.business_members set permissions=perms where business_id=bid and user_id=target and status='active';
   get diagnostics changed=row_count; if changed<>1 then raise exception '활성 직원을 찾지 못했습니다.'; end if;
  when 'transfer_start' then
   select id into target from public.profiles where lower(username)=lower(trim(payload->>'username')) and status='approved';
   if target is null or target=auth.uid() or not exists(select 1 from public.business_members where business_id=bid and user_id=target and status='active') then raise exception '수락한 직원을 후임으로 선택해 주세요.'; end if;
   update public.business_ownership_transfers set status='cancelled' where business_id=bid and status in ('requested','accepted') and expires_at<=now();
   insert into public.business_ownership_transfers(business_id,from_user_id,to_user_id) values(bid,auth.uid(),target) returning id into iid;
  when 'transfer_confirm' then
   if transfer.id is null or transfer.from_user_id<>auth.uid() or transfer.status<>'accepted' or transfer.expires_at<=now()
   or not exists(select 1 from public.business_members where business_id=bid and user_id=transfer.to_user_id and status='active')
   or not exists(select 1 from public.profiles where id=transfer.to_user_id and status='approved') then raise exception '후임의 유효한 수락이 필요합니다.'; end if;
   target:=transfer.to_user_id;
   update public.businesses set owner_id=target,updated_at=now() where id=bid;
   update public.profiles set role='partner' where id=target and role='user';
   update public.business_members set status='removed' where business_id=bid and user_id=target;
   -- Previous representative loses access; business, reservations and settlement history keep their IDs.
   update public.business_members set status='removed' where business_id=bid and user_id=auth.uid();
   update public.business_ownership_transfers set status='confirmed' where id=transfer.id;
   update public.business_staff_invitations set status='revoked' where business_id=bid and status='pending';
  when 'transfer_cancel' then
   update public.business_ownership_transfers set status='cancelled' where id=transfer.id and from_user_id=auth.uid() and status in ('requested','accepted');
  else raise exception '지원하지 않는 업장 작업입니다.';
  end case;
 end if;
 insert into public.business_workspace_audit(business_id,actor_id,action,subject_id,details)
 values(bid,auth.uid(),action,target,jsonb_build_object('permissions',perms));
 return jsonb_build_object('business_id',bid,'invite_token',token,'invitation_id',iid,'transfer_id',iid);
end;
$$;
revoke all on function public.manage_business_workspace(text,jsonb) from public,anon;
grant execute on function public.manage_business_workspace(text,jsonb) to authenticated;

-- Staff can read their workspace, not payout-account rows or other staff profiles.
drop policy if exists business_workspace_read on public.businesses;
create policy business_workspace_read on public.businesses for select to authenticated using(public.can_access_business_workspace(id));
drop policy if exists business_staff_listing_update on public.businesses;
create policy business_staff_listing_update on public.businesses for update to authenticated
 using(public.has_business_permission(id,'listing')) with check(public.has_business_permission(id,'listing'));

create or replace function public.guard_business_workspace_fields()
returns trigger language plpgsql security definer set search_path='' as $$
declare editable text[]:=array['business_name','representative_name','phone','business_number','business_start_date','region','postal_code',
 'address','address_detail','description','short_description','highlight_keys','highlight_summary','facilities','nearby_tags',
 'gallery_image_urls','cover_image_url','room_count','bath_count','shared_bathroom_count','shared_bathroom_gender_separated',
 'shared_bathroom_note','shoulder_season_ranges','peak_season_ranges','amenity_details','extra_fees','latitude','longitude',
 'location_verified_at','station_distance_m','convenience_distance_m','market_open_time','market_close_time_default',
 'market_close_time_friday','market_close_time_saturday','market_approval_minutes','updated_at'];
begin
 if auth.uid() is null or public.is_admin() then return new; end if;
 if old.workspace_closed_at is not null then raise exception '종료된 업장 초안은 수정할 수 없습니다.'; end if;
 if new.owner_id is distinct from old.owner_id and not exists(select 1 from public.business_ownership_transfers t
 where t.business_id=old.id and t.from_user_id=auth.uid() and t.to_user_id=new.owner_id and t.status='accepted' and t.expires_at>now()) then
 raise exception '소유권 이전 절차를 이용해 주세요.'; end if;
 if old.owner_id<>auth.uid() then
  if not public.has_business_permission(old.id,'listing') or (to_jsonb(new)-editable) is distinct from (to_jsonb(old)-editable) then
   raise exception '허용되지 않은 업장 변경입니다.' using errcode='42501'; end if;
 elsif new.approval_status is distinct from old.approval_status or new.business_type is distinct from old.business_type
 or new.owner_workspace_created is distinct from old.owner_workspace_created or new.id<>old.id then
  raise exception '운영팀 심사가 필요한 항목입니다.';
 end if;
 return new;
end;
$$;
drop trigger if exists guard_business_workspace_fields on public.businesses;
create trigger guard_business_workspace_fields before update on public.businesses for each row execute function public.guard_business_workspace_fields();

create or replace function public.clear_revoked_business_presence()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status<>'active' or not('chat'=any(new.permissions)) then
  update public.chat_notification_state s set active_until=null,updated_at=now() from public.conversations c
  where c.id=s.conversation_id and c.business_id=new.business_id and s.recipient_user_id=new.user_id;
 end if;
 return new;
end;
$$;
drop trigger if exists clear_revoked_business_presence on public.business_members;
create trigger clear_revoked_business_presence after update on public.business_members for each row execute function public.clear_revoked_business_presence();
grant select(owner_workspace_created) on public.businesses to authenticated;
commit;
