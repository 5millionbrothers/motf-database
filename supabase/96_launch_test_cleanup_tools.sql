-- Installs preview/archive tools only. Does NOT execute cleanup.
begin;
create table if not exists public.launch_cleanup_backups (
  table_name text not null, row_id uuid not null, snapshot jsonb not null,
  archived_at timestamptz not null default now(), primary key(table_name,row_id)
);
alter table public.launch_cleanup_backups enable row level security;
revoke all on public.launch_cleanup_backups from public,anon,authenticated;
grant select on public.launch_cleanup_backups to service_role;

create or replace function public.preview_launch_test_cleanup()
returns table(table_name text,row_id uuid,can_archive boolean,reason text)
language plpgsql security definer set search_path='' as $$
declare source_name text; row_data jsonb; candidate_id uuid; actor_id text; label text;
begin
  for source_name in select unnest(array['reservations','market_orders','conversations','mt_projects','community_posts','reviews','product_reviews','homepage_cards','popup_banners','recreation_activities','platform_events']) loop
    for row_data in execute format('select to_jsonb(t) from public.%I t',source_name) loop
      candidate_id=(row_data->>'id')::uuid;
      actor_id=coalesce(row_data->>'customer_id',row_data->>'owner_id',row_data->>'author_id',row_data->>'created_by');
      label=coalesce(row_data->>'customer_name',row_data->>'title',row_data->>'author_name','');
      if (row_data->>'launch_archived_at') is null
        and not coalesce((row_data->>'is_hidden')::boolean,false)
        and coalesce((row_data->>'is_active')::boolean,true)
        and (row_data->>'status') is distinct from 'draft'
        and (exists(select 1 from public.profiles p where p.id::text=actor_id and p.is_test_account)
          or label ~* '^\[(테스트|데모|시연|demo|test)\]') then
        table_name=source_name; row_id=candidate_id; can_archive=true; reason='고정 테스트 계정 또는 명시된 테스트 표기';
        if source_name in ('reservations','market_orders') and (
          exists(select 1 from public.payment_intents pi where pi.transaction_id=candidate_id)
          or exists(select 1 from public.partner_settlements s where s.transaction_id=candidate_id)
        ) then
          can_archive=false; reason='결제/정산 원장 연결: PG 상태 확인 후 별도 처리 필요';
        elsif source_name='conversations' and (
          exists(select 1 from public.reservations r where r.business_id=(row_data->>'business_id')::uuid
            and r.customer_id::text=actor_id and exists(select 1 from public.payment_intents pi where pi.transaction_id=r.id))
          or exists(select 1 from public.market_orders o where o.business_id=(row_data->>'business_id')::uuid
            and o.customer_id::text=actor_id and exists(select 1 from public.payment_intents pi where pi.transaction_id=o.id))
        ) then
          can_archive=false; reason='결제 거래가 연결된 대화: 보존';
        end if;
        if not exists(select 1 from public.launch_cleanup_backups b where b.table_name=source_name and b.row_id=candidate_id) then return next; end if;
      end if;
    end loop;
  end loop;
end;
$$;
revoke all on function public.preview_launch_test_cleanup() from public,anon,authenticated;
grant execute on function public.preview_launch_test_cleanup() to service_role;

create or replace function public.archive_launch_verified_tests()
returns integer language plpgsql security definer set search_path='' as $$
declare item record; snapshot jsonb; affected integer:=0;
begin
  -- Serialize repeated execution, retaining the original snapshot for recovery.
  perform pg_advisory_xact_lock(hashtextextended('motf-launch-cleanup-20261116',0));
  for item in select * from public.preview_launch_test_cleanup() where can_archive loop
    execute format('select to_jsonb(t) from public.%I t where id=$1 for update',item.table_name) into snapshot using item.row_id;
    if snapshot is null then continue; end if;
    -- Recheck while the row lock prevents a concurrent payment finalization.
    if item.table_name in ('reservations','market_orders') and (
      exists(select 1 from public.payment_intents pi where pi.transaction_id=item.row_id)
      or exists(select 1 from public.partner_settlements s where s.transaction_id=item.row_id)
    ) then continue; end if;
    insert into public.launch_cleanup_backups(table_name,row_id,snapshot)
    values(item.table_name,item.row_id,snapshot) on conflict do nothing;
    if item.table_name in ('community_posts','reviews','product_reviews') then
      execute format('update public.%I set is_hidden=true where id=$1',item.table_name) using item.row_id;
    elsif item.table_name in ('homepage_cards','popup_banners','recreation_activities') then
      execute format('update public.%I set is_active=false where id=$1',item.table_name) using item.row_id;
    elsif item.table_name='platform_events' then
      update public.platform_events set status='draft' where id=item.row_id;
    elsif item.table_name in ('reservations','market_orders') then
      execute format('update public.%I set status=''cancelled'', launch_archived_at=now() where id=$1',item.table_name) using item.row_id;
    else
      execute format('update public.%I set launch_archived_at=now() where id=$1',item.table_name) using item.row_id;
    end if;
    affected=affected+1;
  end loop;
  return affected;
end;
$$;
revoke all on function public.archive_launch_verified_tests() from public,anon,authenticated;
grant execute on function public.archive_launch_verified_tests() to service_role;
commit;
