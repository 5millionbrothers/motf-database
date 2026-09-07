-- Transfer an imported business to its real owner without moving catalog data.

create or replace function public.admin_transfer_business_ownership(
  target_business_id uuid,
  target_new_owner_id uuid,
  transfer_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_business public.businesses%rowtype;
  target_owner public.profiles%rowtype;
begin
  if not public.is_admin() then
    raise exception '운영자 권한이 필요합니다.';
  end if;

  select *
  into target_business
  from public.businesses
  where id = target_business_id
  for update;

  if not found then
    raise exception '이전할 업장을 찾을 수 없습니다.';
  end if;

  select *
  into target_owner
  from public.profiles
  where id = target_new_owner_id;

  if not found then
    raise exception '새 사장님 계정을 찾을 수 없습니다.';
  end if;

  if target_owner.role not in ('partner', 'admin')
     or target_owner.status <> 'approved' then
    raise exception '승인된 사장님 계정으로만 업장을 이전할 수 있습니다.';
  end if;

  if target_business.owner_id = target_new_owner_id then
    return jsonb_build_object(
      'business_id', target_business.id,
      'previous_owner_id', target_business.owner_id,
      'new_owner_id', target_new_owner_id,
      'changed', false
    );
  end if;

  update public.businesses
  set owner_id = target_new_owner_id,
      updated_at = now()
  where id = target_business_id;

  insert into public.admin_audit_logs(
    admin_id,
    action,
    target_type,
    target_id,
    before_data,
    after_data
  ) values (
    auth.uid(),
    'business_ownership_transfer',
    'business',
    target_business_id::text,
    jsonb_build_object(
      'owner_id', target_business.owner_id,
      'business_name', target_business.business_name
    ),
    jsonb_build_object(
      'owner_id', target_new_owner_id,
      'business_name', target_business.business_name,
      'reason', nullif(btrim(transfer_reason), '')
    )
  );

  return jsonb_build_object(
    'business_id', target_business.id,
    'previous_owner_id', target_business.owner_id,
    'new_owner_id', target_new_owner_id,
    'changed', true
  );
end;
$$;

revoke all on function public.admin_transfer_business_ownership(uuid, uuid, text) from public;
grant execute on function public.admin_transfer_business_ownership(uuid, uuid, text) to authenticated;

comment on function public.admin_transfer_business_ownership(uuid, uuid, text) is
  'Admin-only ownership transfer. Offerings, media, orders, reservations, settlement settings and conversations remain attached to the business.';
