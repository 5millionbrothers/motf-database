-- Apply after 86. Existing groups, member approvals, wallets and handovers are retained.
begin;
alter table public.organizations
  add column if not exists category text,
  add column if not exists institution text,
  add column if not exists department text,
  add column if not exists manager_name text,
  add column if not exists manager_role text,
  add column if not exists manager_phone text,
  add column if not exists manager_email text,
  add column if not exists description text,
  add column if not exists expected_members integer,
  add column if not exists profile_completed_at timestamptz,
  add column if not exists profile_updated_at timestamptz;

do $$ begin
  if to_regprocedure('public.manage_organization_before_db87(text,jsonb)') is null then
    alter function public.manage_organization(text,jsonb) rename to manage_organization_before_db87;
  end if;
end $$;
revoke all on function public.manage_organization_before_db87(text,jsonb) from public,anon,authenticated,service_role;

create or replace function public.manage_organization(action text, payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; oid uuid; kind text; phone text; members integer;
begin
  if action not in ('create','update_profile') then
    return public.manage_organization_before_db87(action,payload);
  end if;
  if auth.uid() is null or not exists(select 1 from public.profiles p
    where p.id=auth.uid() and p.status='approved' and p.withdrawal_processed_at is null) then
    raise exception '로그인이 필요합니다.';
  end if;
  kind:=payload->>'category';
  if kind is null or kind not in ('university_department','university_college','university_council',
    'university_club','university_other','company','religious','youth','club','other') then
    raise exception '단체 유형을 선택해주세요.';
  end if;
  if length(btrim(coalesce(payload->>'name',''))) not between 2 and 80
    or length(btrim(coalesce(payload->>'institution',''))) not between 2 and 120
    or length(btrim(coalesce(payload->>'manager_name',''))) not between 2 and 80
    or length(btrim(coalesce(payload->>'manager_role',''))) not between 1 and 60
    or length(coalesce(payload->>'department',''))>120
    or length(coalesce(payload->>'description',''))>1000 then
    raise exception '단체 이름·학교/기관·담당자 이름과 역할을 확인해주세요.';
  end if;
  phone:=regexp_replace(coalesce(payload->>'manager_phone',''),'[^0-9]','','g');
  if phone !~ '^0[0-9]{8,10}$' then raise exception '담당자 연락처를 확인해주세요.'; end if;
  if length(coalesce(payload->>'manager_email',''))>254 or
    (nullif(btrim(payload->>'manager_email'),'') is not null and
      payload->>'manager_email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception '이메일 형식을 확인해주세요.';
  end if;
  members:=nullif(payload->>'expected_members','')::integer;
  if members is not null and (members<1 or members>100000) then raise exception '단체 규모를 확인해주세요.'; end if;
  if not coalesce((payload->>'contact_consent')::boolean,false) then
    raise exception '담당자 정보의 단체 관리 목적 이용을 확인해주세요.';
  end if;
  if action='create' then
    result:=public.manage_organization_before_db87('create',payload||jsonb_build_object('affiliation',btrim(payload->>'institution')));
    oid:=(result->>'organization_id')::uuid;
  else
    oid:=(payload->>'organization_id')::uuid;
    perform 1 from public.organizations o where o.id=oid and o.status='active' for update;
    if not found or not public.is_organization_representative(oid) then
      raise exception '현재 대표 담당자만 단체 정보를 수정할 수 있습니다.';
    end if;
    result:=jsonb_build_object('organization_id',oid);
  end if;
  update public.organizations o set name=btrim(payload->>'name'),
    affiliation=btrim(payload->>'institution'),category=kind,institution=btrim(payload->>'institution'),
    department=nullif(btrim(payload->>'department'),''),manager_name=btrim(payload->>'manager_name'),
    manager_role=btrim(payload->>'manager_role'),manager_phone=phone,
    manager_email=nullif(btrim(payload->>'manager_email'),''),description=nullif(btrim(payload->>'description'),''),
    expected_members=members,profile_completed_at=coalesce(o.profile_completed_at,now()),profile_updated_at=now()
    where o.id=oid;
  insert into public.organization_audit(organization_id,actor_id,action,details)
    values(oid,auth.uid(),'profile_saved',jsonb_build_object('category',kind));
  return result;
end;
$$;
revoke all on function public.manage_organization(text,jsonb) from public,anon;
grant execute on function public.manage_organization(text,jsonb) to authenticated;

create or replace function public.organization_history(target_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not public.is_organization_member(target_id) then raise exception '단체 기록에 접근할 권한이 없습니다.'; end if;
  return jsonb_build_object(
    'projects',coalesce((select jsonb_agg(to_jsonb(t) order by t.starts_on desc) from (
      select p.id,p.title,p.starts_on,p.ends_on,p.guest_count,p.region,p.estimated_budget,p.status
      from public.mt_projects p where p.organization_id=target_id order by p.starts_on desc limit 200
    ) t),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from (
      select r.id,'stay' as kind,b.business_name as title,r.status,r.created_at,
        coalesce((to_jsonb(r)->>'total_amount')::numeric,0) as amount
      from public.reservations r join public.businesses b on b.id=r.business_id where r.organization_id=target_id
      union all
      select o.id,'market',b.business_name,o.status,o.created_at,o.total_amount
      from public.market_orders o join public.businesses b on b.id=o.business_id where o.organization_id=target_id
      order by created_at desc limit 200
    ) t),'[]'::jsonb));
end;
$$;
revoke all on function public.organization_history(uuid) from public,anon;
grant execute on function public.organization_history(uuid) to authenticated;

-- Keep the public contact profile aligned with the explicitly confirmed representative transfer.
create or replace function public.sync_organization_representative_contact()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.representative_id is distinct from old.representative_id then
    select p.full_name,p.phone into new.manager_name,new.manager_phone from public.profiles p where p.id=new.representative_id;
    new.manager_role:='대표 담당자';
    new.manager_email:=null;
    new.profile_updated_at:=now();
  end if;
  return new;
end;
$$;
revoke all on function public.sync_organization_representative_contact() from public;
drop trigger if exists sync_organization_representative_contact on public.organizations;
create trigger sync_organization_representative_contact before update of representative_id on public.organizations
for each row execute function public.sync_organization_representative_contact();
commit;
