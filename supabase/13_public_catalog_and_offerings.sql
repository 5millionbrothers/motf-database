-- 실제 업장·객실·상품 공개 카탈로그 연결

alter table public.businesses
  add column if not exists region text,
  add column if not exists cover_image_url text,
  add column if not exists facilities text[] not null default '{}';

alter table public.offerings
  add column if not exists max_people integer check (max_people is null or max_people > 0),
  add column if not exists unit text,
  add column if not exists category text,
  add column if not exists image_url text,
  add column if not exists sort_order integer not null default 0;

grant update (region, cover_image_url, facilities, updated_at)
on public.businesses to authenticated;

grant delete on public.offerings to authenticated;

create policy "offerings_partner_delete"
on public.offerings for delete to authenticated
using (public.owns_business(business_id) or public.is_admin());

create policy "businesses_public_read_approved"
on public.businesses for select to anon, authenticated
using (approval_status = 'approved');

create policy "offerings_public_read_active"
on public.offerings for select to anon
using (
  is_active
  and exists (
    select 1 from public.businesses b
    where b.id = business_id and b.approval_status = 'approved'
  )
);

grant usage on schema public to anon;
grant select (
  id, business_type, business_name, address, description,
  region, cover_image_url, facilities, approval_status
) on public.businesses to anon;

grant select (
  id, business_id, name, description, price, is_active,
  max_people, unit, category, image_url, sort_order
) on public.offerings to anon;

create or replace function public.set_business_offerings_active(
  target_business_id uuid,
  active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  update public.offerings
  set is_active = active,
      updated_at = now()
  where business_id = target_business_id;
end;
$$;

revoke all on function public.set_business_offerings_active(uuid, boolean) from public;
grant execute on function public.set_business_offerings_active(uuid, boolean) to authenticated;

create or replace function public.save_business_offerings(
  target_business_id uuid,
  items jsonb
)
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
    business_id, name, description, price, is_active,
    max_people, unit, category, image_url, sort_order
  )
  select
    target_business_id,
    nullif(trim(item ->> 'name'), ''),
    nullif(trim(item ->> 'description'), ''),
    greatest(coalesce((item ->> 'price')::integer, 0), 0),
    true,
    nullif(item ->> 'max_people', '')::integer,
    nullif(trim(item ->> 'unit'), ''),
    nullif(trim(item ->> 'category'), ''),
    nullif(trim(item ->> 'image_url'), ''),
    coalesce((item ->> 'sort_order')::integer, 0)
  from jsonb_array_elements(items) as item;

  if exists (
    select 1 from public.offerings
    where business_id = target_business_id and name is null
  ) then
    raise exception '객실 또는 상품 이름을 입력해주세요.';
  end if;
end;
$$;

revoke all on function public.save_business_offerings(uuid, jsonb) from public;
grant execute on function public.save_business_offerings(uuid, jsonb) to authenticated;
