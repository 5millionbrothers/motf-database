-- Archive obsolete hidden room copies. Keep IDs and every booking reference intact.
begin;
create table if not exists public.room_copy_repair_audit (
  offering_id uuid primary key,
  business_id uuid not null,
  original_row jsonb not null,
  repaired_at timestamptz not null default now()
);
alter table public.room_copy_repair_audit enable row level security;
revoke all on public.room_copy_repair_audit from public,anon,authenticated;
grant select on public.room_copy_repair_audit to authenticated;
drop policy if exists room_copy_repair_admin on public.room_copy_repair_audit;
create policy room_copy_repair_admin on public.room_copy_repair_audit
  for select to authenticated using (public.is_admin());

do $$
declare bid uuid;
begin
  for bid in select id from public.businesses where business_type='stay' order by id loop
    perform 1 from public.businesses where id=bid for update;
    insert into public.room_copy_repair_audit(offering_id,business_id,original_row)
    select o.id,o.business_id,to_jsonb(o) from public.offerings o
    where o.business_id=bid and not o.is_active and o.retired_at is null
      and (select count(*) from public.offerings a where a.business_id=bid
        and a.is_active and a.retired_at is null and lower(trim(a.name))=lower(trim(o.name)))=1
    on conflict(offering_id) do nothing;
    update public.offerings o set retired_at=now(),updated_at=now()
    where o.business_id=bid and not o.is_active and o.retired_at is null
      and exists(select 1 from public.room_copy_repair_audit a where a.offering_id=o.id)
      and (select count(*) from public.offerings a where a.business_id=bid
        and a.is_active and a.retired_at is null and lower(trim(a.name))=lower(trim(o.name)))=1;
  end loop;
end;
$$;
notify pgrst,'reload schema';
commit;
