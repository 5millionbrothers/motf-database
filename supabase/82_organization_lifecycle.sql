-- Apply after SQL76-81. No historical organization, payer, or ledger rows are deleted.
begin;
alter table public.organizations
 add column if not exists status text not null default 'active' check(status in ('active','closed')),
 add column if not exists closed_at timestamptz,
 add column if not exists closed_by uuid references public.profiles(id),
 add column if not exists closure_reason text;

create or replace function public.is_organization_member(target_id uuid, target_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_members m
 join public.organizations o on o.id=m.organization_id
 join public.profiles p on p.id=m.user_id
 where o.id=target_id and o.status='active' and m.user_id=target_user
 and m.status='active' and p.status='approved' and p.withdrawal_processed_at is null);
$$;

-- Administrators retain read access for audit; closed group chats are no longer workspaces.
create or replace function public.can_access_conversation(target_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.status='approved' and p.withdrawal_processed_at is null)
 and exists(select 1 from public.conversations c where c.id=target_id and (
 public.is_admin() or ((c.organization_id is null or exists(select 1 from public.organizations o
 where o.id=c.organization_id and o.status='active')) and (
 public.has_business_permission(c.business_id,'chat')
 or case when c.organization_id is null then c.customer_id=auth.uid() else public.is_organization_member(c.organization_id) end))));
$$;
revoke all on function public.can_access_conversation(uuid) from public;
grant execute on function public.can_access_conversation(uuid) to authenticated,service_role;

-- Follow immutable transaction/payer links, never current organization membership.
create or replace function public.lifecycle_has_open_transactions(target_organization uuid, target_user uuid)
returns boolean language sql stable security definer set search_path='' as $$
 with transactions as (
 select r.id, 'stay'::text as kind, r.status, r.payment_status, r.refund_status
 from public.reservations r where
 (target_organization is not null and r.organization_id=target_organization) or
 (target_user is not null and (r.customer_id=target_user or r.booking_contact_user_id=target_user)) or
 exists(select 1 from public.payment_intents pi where pi.transaction_id=r.id and pi.kind='stay'
 and ((target_user is not null and pi.customer_id=target_user) or
 (target_organization is not null and pi.organization_id=target_organization)))
 union all
 select o.id, 'market', o.status, o.payment_status, o.refund_status
 from public.market_orders o where
 (target_organization is not null and o.organization_id=target_organization) or
 (target_user is not null and (o.customer_id=target_user or o.booking_contact_user_id=target_user)) or
 exists(select 1 from public.payment_intents pi where pi.transaction_id=o.id and pi.kind='market'
 and ((target_user is not null and pi.customer_id=target_user) or
 (target_organization is not null and pi.organization_id=target_organization)))
 ), intents as (
 select pi.* from public.payment_intents pi where
 (target_organization is not null and pi.organization_id=target_organization) or
 (target_user is not null and pi.customer_id=target_user) or
 exists(select 1 from transactions t where t.id=pi.transaction_id and t.kind=pi.kind)
 )
 select exists(select 1 from transactions where status in ('pending','confirmed')
 or payment_status in ('refund_required','refund_processing','refund_failed')
 or refund_status in ('required','processing','failed'))
 or exists(select 1 from intents where refund_status in ('required','processing','failed')
 or (status in ('prepared','virtual_account_issued') and coalesce(expires_at,
 virtual_account_issued_at+interval '24 hours',created_at+interval '30 minutes')>now()))
 or exists(select 1 from public.partner_settlements s where s.status not in ('paid','cancelled')
 and (exists(select 1 from transactions t where t.id=s.transaction_id and t.kind=s.transaction_kind)
 or exists(select 1 from intents pi where pi.transaction_id=s.transaction_id and pi.kind=s.transaction_kind)));
$$;
revoke all on function public.lifecycle_has_open_transactions(uuid,uuid) from public,anon,authenticated,service_role;

create or replace function public.close_organization(target_organization_id uuid, reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare org public.organizations%rowtype; cleaned_reason text:=btrim(reason);
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid()
 and status='approved' and withdrawal_processed_at is null) then raise exception '로그인이 필요합니다.'; end if;
 select * into org from public.organizations where id=target_organization_id for update;
 if org.id is null then raise exception '단체를 찾지 못했습니다.'; end if;
 if not public.is_admin() and not (org.representative_id=auth.uid()
 and public.is_organization_member(org.id)) then raise exception '대표 담당자 또는 관리자만 단체를 폐쇄할 수 있습니다.'; end if;
 if cleaned_reason is null or length(cleaned_reason)<6 or length(cleaned_reason)>500 then
 raise exception '폐쇄 사유를 6~500자로 입력해주세요.'; end if;
 if org.status<>'active' then raise exception '이미 폐쇄된 단체입니다.'; end if;
 perform 1 from public.organization_point_accounts where organization_id=org.id for update;
 if public.lifecycle_has_open_transactions(org.id,null) then
 raise exception '진행 중인 단체 예약, 주문, 결제, 환불 또는 정산이 있어 폐쇄할 수 없습니다.'; end if;
 if exists(select 1 from public.organization_point_accounts where organization_id=org.id and balance<>0)
 or exists(select 1 from public.point_holds where organization_id=org.id and status='held' and expires_at>now()) then
 raise exception '미사용 단체 포인트 또는 포인트 보관 건이 있어 폐쇄할 수 없습니다. 단체 포인트 처리 정책 확인을 위해 운영팀에 문의해주세요. 개인 포인트로 자동 이전되지 않습니다.'; end if;
 update public.organizations set status='closed',closed_at=now(),closed_by=auth.uid(),closure_reason=cleaned_reason where id=org.id;
 update public.organization_invites set revoked_at=coalesce(revoked_at,now()) where organization_id=org.id;
 update public.organization_transfers set status='cancelled' where organization_id=org.id and status in ('requested','accepted');
 update public.organization_members set status='removed' where organization_id=org.id and status in ('active','pending');
 update public.notification_outbox n set status='cancelled',last_error='단체 폐쇄',updated_at=now()
 from public.conversations c where c.organization_id=org.id and n.status='queued'
 and n.event_key='chat_received' and split_part(n.dedupe_key,':',2)=c.id::text;
 update public.chat_notification_state s set active_until=now(),last_notified_message_id=null,updated_at=now()
 from public.conversations c where c.organization_id=org.id and s.conversation_id=c.id;
 insert into public.organization_audit(organization_id,actor_id,action,details)
 values(org.id,auth.uid(),'close',jsonb_build_object('reason',cleaned_reason,'previous_status',org.status));
 return jsonb_build_object('organization_id',org.id,'status','closed');
end;
$$;
revoke all on function public.close_organization(uuid,text) from public;
grant execute on function public.close_organization(uuid,text) to authenticated;

-- Keep SQL76 behavior in an owner-only implementation; all public entry points lock lifecycle first.
do $$ begin
 if to_regprocedure('public.manage_organization_before_db82(text,jsonb)') is null then
 alter function public.manage_organization(text,jsonb) rename to manage_organization_before_db82;
 end if;
end $$;
revoke all on function public.manage_organization_before_db82(text,jsonb) from public,anon,authenticated,service_role;
create or replace function public.manage_organization(action text, payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare oid uuid; lifecycle text;
begin
 if action='close' then return public.close_organization((payload->>'organization_id')::uuid,payload->>'reason'); end if;
 if action='accept_invite' then
 select organization_id into oid from public.organization_invites where token=payload->>'token';
 elsif action<>'create' then oid:=(payload->>'organization_id')::uuid;
 end if;
 if action<>'create' then
 select status into lifecycle from public.organizations where id=oid for update;
 if lifecycle is distinct from 'active' then raise exception '폐쇄되었거나 이용할 수 없는 단체입니다.'; end if;
 end if;
 return public.manage_organization_before_db82(action,payload);
end;
$$;
revoke all on function public.manage_organization(text,jsonb) from public;
grant execute on function public.manage_organization(text,jsonb) to authenticated;

create or replace function public.assert_account_withdrawal_allowed(target_user uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.organizations where representative_id=target_user and status='active') then
 raise exception '단체 대표 담당자는 먼저 인계 또는 단체 폐쇄를 완료해주세요.'; end if;
 -- SQL80 keeps businesses.owner_id as the authoritative representative, including drafts/suspended rows.
 if exists(select 1 from public.businesses where owner_id=target_user and workspace_closed_at is null) then
 raise exception '업장 대표 담당자는 모든 업장의 인계를 먼저 완료해주세요.'; end if;
 if public.lifecycle_has_open_transactions(null,target_user)
 or exists(select 1 from public.point_holds where user_id=target_user and status='held' and expires_at>now()) then
 raise exception '진행 중인 예약, 주문, 결제, 환불, 정산 또는 포인트 보관 건이 있어 탈퇴할 수 없습니다.'; end if;
end;
$$;
revoke all on function public.assert_account_withdrawal_allowed(uuid) from public,anon,authenticated,service_role;
create or replace function public.request_account_withdrawal(request_reason text default null, anonymized_email text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 perform 1 from public.profiles where id=auth.uid() for update;
 perform public.assert_account_withdrawal_allowed(auth.uid());
 update public.profiles set status='suspended',
 email=coalesce(nullif(btrim(anonymized_email),''),email),full_name='탈퇴 회원',phone=null,organization=null,
 withdrawal_requested_at=coalesce(withdrawal_requested_at,now()),
 withdrawal_processed_at=coalesce(withdrawal_processed_at,now()),
 withdrawal_reason=nullif(btrim(request_reason),''),
 withdrawal_anonymized_email=nullif(btrim(anonymized_email),''),updated_at=now()
 where id=auth.uid() and role in ('user','partner');
 if not found then raise exception '탈퇴 요청은 이용자 또는 사장님 계정에서만 가능합니다.'; end if;
 update public.conversations set customer_name='탈퇴 회원',group_name=case when organization_id is null then null else group_name end
 where customer_id=auth.uid();
end;
$$;
revoke all on function public.request_account_withdrawal(text,text) from public;
grant execute on function public.request_account_withdrawal(text,text) to authenticated;
create or replace function public.guard_organization_withdrawal()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.withdrawal_processed_at is not null and old.withdrawal_processed_at is null then
 perform public.assert_account_withdrawal_allowed(old.id);
 insert into public.organization_audit(organization_id,actor_id,action,subject_id)
 select organization_id,old.id,'account_withdrawal',old.id from public.organization_members
 where user_id=old.id and status in ('active','pending');
 insert into public.business_workspace_audit(business_id,actor_id,action,subject_id)
 select business_id,old.id,'account_withdrawal',old.id from public.business_members where user_id=old.id and status='active';
 update public.business_members set status='removed' where user_id=old.id and status='active';
 update public.business_staff_invitations set status='revoked' where (invited_user_id=old.id or created_by=old.id) and status='pending';
 update public.business_ownership_transfers set status='cancelled' where (from_user_id=old.id or to_user_id=old.id) and status in ('requested','accepted');
 update public.business_transfer_verifications set consumed_at=coalesce(consumed_at,now()) where user_id=old.id;
 update public.organization_members set status='removed' where user_id=old.id and status in ('active','pending');
 update public.organization_invites set revoked_at=coalesce(revoked_at,now()) where created_by=old.id;
 update public.organization_transfers set status='cancelled' where (requested_by=old.id or recipient_id=old.id)
 and status in ('requested','accepted');
 update public.notification_outbox set status='cancelled',last_error='회원 탈퇴',updated_at=now()
 where recipient_user_id=old.id and status='queued';
 update public.chat_notification_state set active_until=now(),last_notified_message_id=null,updated_at=now()
 where recipient_user_id=old.id;
 end if;
 return new;
end;
$$;

-- Transaction writers serialize with closure/withdrawal, including service-role checkout finalization.
create or replace function public.guard_lifecycle_write()
returns trigger language plpgsql security definer set search_path='' as $$
declare row_data jsonb:=to_jsonb(new); oid uuid; payer uuid; lifecycle text; withdrawn timestamptz;
 refund_credit boolean:=false;
begin
 oid:=nullif(row_data->>'organization_id','')::uuid;
 if tg_table_name='businesses' then
 payer:=(row_data->>'owner_id')::uuid;
 elsif tg_table_name='organizations' then
 if tg_op='UPDATE' and old.status='closed' and new.status is distinct from old.status then
 raise exception '폐쇄된 단체는 다시 활성화할 수 없습니다.'; end if;
 if row_data->>'status'='active' then payer:=(row_data->>'representative_id')::uuid; end if;
 elsif tg_table_name in ('organization_members','business_members') then
 if row_data->>'status' in ('active','pending') then payer:=(row_data->>'user_id')::uuid; end if;
 elsif tg_table_name='messages' then
 select organization_id into oid from public.conversations where id=(row_data->>'conversation_id')::uuid;
 end if;
 if oid is not null then
 select status into lifecycle from public.organizations where id=oid for update;
 if lifecycle='closed' and tg_table_name='organization_point_ledger' and tg_op='INSERT' then
 refund_credit:=row_data->>'entry_type'='refund' and (row_data->>'amount')::integer>0
 and exists(select 1 from public.payment_intents pi where pi.organization_id=oid
 and pi.transaction_id=(row_data->>'source_id')::uuid and 'payment_refund_'||pi.kind=row_data->>'source_type'
 and pi.refund_status='refunded' and pi.points_used>=(row_data->>'amount')::integer);
 elsif lifecycle='closed' and tg_table_name='organization_point_accounts' and tg_op='UPDATE' then
 refund_credit:=new.balance>old.balance and new.balance-old.balance<=old.lifetime_used
 and new.lifetime_used=old.lifetime_used-(new.balance-old.balance) and new.lifetime_earned=old.lifetime_earned;
 end if;
 if lifecycle='closed' and not coalesce(refund_credit,false) and (tg_op='INSERT'
 or row_data->>'status' in ('pending','confirmed','prepared','virtual_account_issued','held','requested','accepted')
 or row_data->>'refund_status' in ('required','processing','failed')
 or (tg_table_name='organization_point_accounts' and (row_data->>'balance')::integer<>0)) then
 raise exception '폐쇄된 단체에는 새 작업을 등록할 수 없습니다.'; end if;
 end if;
 if tg_table_name='point_holds' then payer:=(row_data->>'user_id')::uuid; end if;
 if payer is not null then
 select withdrawal_processed_at into withdrawn from public.profiles where id=payer for update;
 if withdrawn is not null and (tg_op='INSERT'
 or tg_table_name='businesses'
 or tg_table_name in ('organizations','organization_members','business_members')
 or row_data->>'status' in ('pending','confirmed','prepared','virtual_account_issued','held')
 or row_data->>'refund_status' in ('required','processing','failed')) then
 raise exception '탈퇴한 계정에는 진행 중인 거래를 등록할 수 없습니다.'; end if;
 end if;
 return new;
end;
$$;
revoke all on function public.guard_lifecycle_write(),public.guard_organization_withdrawal() from public;
do $$ declare t text; begin
 foreach t in array array['point_holds','organization_point_accounts',
 'organization_members','organization_invites','organization_transfers','organization_point_ledger',
 'mt_projects','conversations','businesses','organizations','business_members'] loop
 execute format('drop trigger if exists guard_lifecycle_write on public.%I',t);
 execute format('create trigger guard_lifecycle_write before insert or update on public.%I for each row execute function public.guard_lifecycle_write()',t);
 end loop;
end $$;
drop trigger if exists guard_lifecycle_write on public.messages;
create trigger guard_lifecycle_write before insert on public.messages for each row execute function public.guard_lifecycle_write();

-- A post-closure refund can restore only the original organization wallet, with its source ledger audit.
create or replace function public.guard_closed_organization_refund_credit()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.balance>old.balance and exists(select 1 from public.organizations where id=new.organization_id and status='closed')
 and not exists(select 1 from public.organization_point_ledger l join public.payment_intents pi
 on pi.organization_id=l.organization_id and pi.transaction_id=l.source_id and l.source_type='payment_refund_'||pi.kind
 where l.organization_id=new.organization_id and l.entry_type='refund' and l.amount=new.balance-old.balance
 and l.balance_after=new.balance and l.created_at=now() and pi.refund_status='refunded' and l.amount<=pi.points_used) then
 raise exception '폐쇄된 단체 포인트 복구에는 기존 환불 거래와 감사 원장이 필요합니다.';
 end if;
 return new;
end;
$$;
revoke all on function public.guard_closed_organization_refund_credit() from public;
drop trigger if exists guard_closed_organization_refund_credit on public.organization_point_accounts;
create constraint trigger guard_closed_organization_refund_credit after update on public.organization_point_accounts
 deferrable initially deferred for each row execute function public.guard_closed_organization_refund_credit();

-- Zero-point checkouts also lock the organization. Fund-safe updates to old history remain possible.
create or replace function public.guard_org_transaction_lifecycle()
returns trigger language plpgsql security definer set search_path='' as $$
declare lifecycle text; payer_status text; withdrawn timestamptz; assigning boolean;
begin
 assigning:=tg_op='INSERT';
 if tg_op='UPDATE' then assigning:=new.organization_id is distinct from old.organization_id; end if;
 if not assigning then return new; end if;
 if new.organization_id is not null then
 select status into lifecycle from public.organizations where id=new.organization_id for update;
 if lifecycle is distinct from 'active' then raise exception '폐쇄되었거나 이용할 수 없는 단체에는 새 거래를 등록할 수 없습니다.'; end if;
 end if;
 select status,withdrawal_processed_at into payer_status,withdrawn from public.profiles where id=new.customer_id for update;
 if payer_status is distinct from 'approved' or withdrawn is not null then
 raise exception '탈퇴했거나 이용할 수 없는 계정에는 새 거래를 등록할 수 없습니다.'; end if;
 return new;
end;
$$;
revoke all on function public.guard_org_transaction_lifecycle() from public;
do $$ declare t text; begin
 foreach t in array array['payment_intents','reservations','market_orders'] loop
 execute format('drop trigger if exists guard_lifecycle_write on public.%I',t);
 execute format('drop trigger if exists guard_org_transaction_lifecycle on public.%I',t);
 execute format('create trigger guard_org_transaction_lifecycle before insert or update of organization_id on public.%I for each row execute function public.guard_org_transaction_lifecycle()',t);
 end loop;
 -- Old DB82 drafts used a stricter settlement update guard. Historical refunds/settlements must remain serviceable.
 drop trigger if exists guard_lifecycle_write on public.partner_settlements;
end $$;
create or replace function public.discard_business_workspace_draft(target_business_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare b public.businesses%rowtype;
begin
 select * into b from public.businesses where id=target_business_id for update;
 if b.id is null or b.owner_id<>auth.uid() or not public.can_access_business_workspace(b.id)
 or b.approval_status not in ('pending','rejected') then raise exception '미승인 업장 초안만 대표가 정리할 수 있습니다.'; end if;
 if exists(select 1 from public.reservations where business_id=b.id)
 or exists(select 1 from public.market_orders where business_id=b.id)
 or exists(select 1 from public.payment_intents where draft->>'business_id'=b.id::text)
 or exists(select 1 from public.partner_settlements where business_id=b.id) then
 raise exception '거래 기록이 있는 업장은 초안 정리 대신 운영팀 확인이 필요합니다.'; end if;
 update public.businesses set workspace_closed_at=now(),updated_at=now() where id=b.id;
 update public.business_members set status='removed' where business_id=b.id;
 update public.business_staff_invitations set status='revoked' where business_id=b.id and status='pending';
 update public.business_ownership_transfers set status='cancelled' where business_id=b.id and status in ('requested','accepted');
 update public.business_listing_review_requests set status='cancelled',updated_at=now() where business_id=b.id and status='pending';
 insert into public.business_workspace_audit(business_id,actor_id,action) values(b.id,auth.uid(),'discard_draft');
end;
$$;
revoke all on function public.discard_business_workspace_draft(uuid) from public,anon;
grant execute on function public.discard_business_workspace_draft(uuid) to authenticated;

create or replace function public.admin_list_organization_workspaces()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_admin() or not exists(select 1 from public.profiles where id=auth.uid()
 and status='approved' and withdrawal_processed_at is null) then raise exception '운영팀 권한이 필요합니다.'; end if;
 return coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('members',coalesce((
 select jsonb_agg(jsonb_build_object('user_id',m.user_id,'username',p.username,'full_name',p.full_name,
 'role',m.role,'identity_verified',p.identity_verified_at is not null) order by m.joined_at)
 from public.organization_members m join public.profiles p on p.id=m.user_id where m.organization_id=o.id
 and m.status='active' and p.status='approved' and p.withdrawal_processed_at is null),'[]'::jsonb)))
 from (select * from public.organizations where status='active' order by created_at desc limit 100) o),'[]'::jsonb);
end;
$$;
revoke all on function public.admin_list_organization_workspaces() from public,anon;
grant execute on function public.admin_list_organization_workspaces() to authenticated;
commit;
