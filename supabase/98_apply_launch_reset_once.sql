-- Explicit one-time reset requested on 2026-11-16.
-- Backups and financial records are retained. Re-running DOES NOT reset new activity.
begin;
do $reset$
declare
 key constant text:='launch-reset-20261116'; cutoff timestamptz; prior jsonb;
 source_name text; item record; fk record; referenced boolean; can_delete boolean;
 deleted_products integer:=0; retained_products integer:=0; count_rows integer;
 removed_ids uuid[]:='{}'; result_data jsonb:='{}';
begin
 perform pg_advisory_xact_lock(hashtextextended(key,0));
 select r.result into prior from public.launch_reset_runs r where r.run_key=key;
 if found then raise notice 'Reset already applied; new activity has not been changed: %',prior; return; end if;
 lock table public.offerings,public.reservations,public.market_orders,public.payment_intents,
   public.conversations,public.messages,public.partner_settlements in share row exclusive mode;
 cutoff=clock_timestamp();
 insert into public.launch_reset_runs(run_key,reset_at) values(key,cutoff);

 for source_name in select unnest(array['reservations','market_orders','payment_intents','partner_settlements','conversations']) loop
   execute format('insert into public.launch_reset_backups(run_key,table_name,row_id,snapshot) select $1,$2,t.id,to_jsonb(t) from public.%I t',source_name) using key,source_name;
   execute format('update public.%I set launch_archived_at=coalesce(launch_archived_at,$1)',source_name) using cutoff;
   get diagnostics count_rows=row_count;
   result_data=result_data||jsonb_build_object(source_name,count_rows);
 end loop;
 update public.conversations set history_started_at=cutoff,customer_opened_at=null;

 -- No order/booking status changes: never pretend that a PG payment was refunded.
 -- Only nonfinancial/manual availability blocks may be released automatically.
 insert into public.launch_reset_backups(run_key,table_name,row_id,snapshot)
 select key,'stay_availability_blocks',b.id,to_jsonb(b) from public.stay_availability_blocks b
 where b.status='active' and b.created_at<cutoff and b.payment_intent_id is null
 and not exists(select 1 from public.payment_intents p where p.transaction_id=b.reservation_id)
 and not exists(select 1 from public.partner_settlements s where s.transaction_id=b.reservation_id);
 update public.stay_availability_blocks b set status='cancelled'
 where exists(select 1 from public.launch_reset_backups z where z.run_key=key and z.table_name='stay_availability_blocks' and z.row_id=b.id);
 get diagnostics count_rows=row_count;
 result_data=result_data||jsonb_build_object('released_nonfinancial_blocks',count_rows,
   'retained_active_blocks',(select count(*) from public.stay_availability_blocks where status='active'));

 for item in select * from public.offerings where business_id='d5513697-7341-4cc6-a16b-781caf6b902d' and not is_active for update loop
   insert into public.launch_reset_backups(run_key,table_name,row_id,snapshot) values(key,'offerings',item.id,to_jsonb(item));
   removed_ids=array_append(removed_ids,item.id);
   update public.offerings set retired_at=coalesce(retired_at,cutoff),is_active=false where id=item.id;
   can_delete=not exists(select 1 from public.mt_project_items m where m.reference_id::text=item.id::text);
   -- Check every FK, including CASCADE/SET NULL references, before physical deletion.
   for fk in
     select ns.nspname as schema_name,rel.relname as table_name,a.attname as column_name,cardinality(c.conkey) as key_count
     from pg_catalog.pg_constraint c join pg_catalog.pg_class rel on rel.oid=c.conrelid
     join pg_catalog.pg_namespace ns on ns.oid=rel.relnamespace
     join pg_catalog.pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
     where c.contype='f' and c.confrelid='public.offerings'::regclass
   loop
     if fk.key_count<>1 then can_delete=false; exit; end if;
     execute format('select exists(select 1 from %I.%I where %I=$1)',fk.schema_name,fk.table_name,fk.column_name) into referenced using item.id;
     if referenced then can_delete=false; exit; end if;
   end loop;
   if can_delete then delete from public.offerings where id=item.id; deleted_products=deleted_products+1;
   else retained_products=retained_products+1; end if;
 end loop;
 -- Stale review payloads must not restore the removed catalogue on a later approval.
 insert into public.launch_reset_backups(run_key,table_name,row_id,snapshot)
 select key,'business_listing_review_requests',r.id,to_jsonb(r) from public.business_listing_review_requests r
 where r.business_id='d5513697-7341-4cc6-a16b-781caf6b902d' and r.status='pending'
 and exists(select 1 from jsonb_array_elements(coalesce(r.proposed_offerings,'[]')) p where p->>'id'=any(removed_ids::text[]));
 update public.business_listing_review_requests r set status='cancelled',review_note='출시 초기화로 예전 상품이 제거되었습니다. 현재 상품 기준으로 다시 신청해주세요.'
 where exists(select 1 from public.launch_reset_backups b where b.run_key=key and b.table_name='business_listing_review_requests' and b.row_id=r.id);

 -- Prevent old queued chat alerts from delivering after a fresh conversation starts.
 insert into public.launch_reset_backups(run_key,table_name,row_id,snapshot)
 select key,'notification_outbox',o.id,to_jsonb(o) from public.notification_outbox o
 where o.template_key like '%CHAT%' and o.status in ('queued','failed') and o.created_at<cutoff;
 update public.notification_outbox o set status='cancelled'
 where exists(select 1 from public.launch_reset_backups b where b.run_key=key and b.table_name='notification_outbox' and b.row_id=o.id);
 result_data=result_data||jsonb_build_object('deleted_inactive_products',deleted_products,'retired_referenced_products',retained_products,'reset_at',cutoff);
 update public.launch_reset_runs r set result=result_data where r.run_key=key;
 raise notice 'Launch reset completed: %',result_data;
end;
$reset$;
commit;
select * from public.launch_reset_runs where run_key='launch-reset-20261116';
