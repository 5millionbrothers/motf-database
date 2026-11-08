begin;
create or replace function public.save_mt_room_candidates(target_project_id uuid,target_business_id uuid,target_offering_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare project public.mt_projects%rowtype; room public.offerings%rowtype; ids uuid[]; rid uuid;
  base integer; candidate uuid; saved jsonb:='[]'; existing_count integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select * into project from public.mt_projects p where p.id=target_project_id and public.can_edit_mt_project(p.id) for update;
  if project.id is null or project.status in ('completed','cancelled') then raise exception '수정 가능한 MT를 선택해주세요.'; end if;
  select array_agg(distinct id) into ids from unnest(target_offering_ids) id where id is not null;
  if coalesce(cardinality(ids),0) not between 1 and 30 then raise exception '객실을 1~30개 선택해주세요.'; end if;
  if not exists(select 1 from public.businesses b where b.id=target_business_id and b.business_type='stay' and b.approval_status='approved') then
    raise exception '이용 가능한 숙소를 선택해주세요.';
  end if;
  select count(*) into existing_count from public.mt_project_candidates c where c.project_id=project.id and not(c.offering_id=any(ids));
  if existing_count+cardinality(ids)>30 then raise exception 'MT별 객실 후보는 최대 30개입니다.'; end if;
  foreach rid in array ids loop
    select * into room from public.offerings o where o.id=rid and o.business_id=target_business_id and o.is_active;
    if room.id is null or not public.stay_range_is_available(rid,project.starts_on,project.ends_on) then
      raise exception '선택한 객실 중 예약할 수 없는 객실이 있습니다. 공실을 다시 확인해주세요.';
    end if;
    base:=public.calculate_stay_base_amount(rid,project.starts_on,project.ends_on);
    insert into public.mt_project_candidates(project_id,business_id,offering_id,estimated_cost,sort_order)
    values(project.id,target_business_id,rid,jsonb_build_object('room_total',base,'confirmed',base,'total',base,
      'extra_person_fee',coalesce(room.extra_person_fee,0),'room_names',jsonb_build_array(room.name)),
      (extract(epoch from clock_timestamp())::bigint%1000000)::integer)
    on conflict(project_id,offering_id) do update set estimated_cost=excluded.estimated_cost
    returning id into candidate;
    saved:=saved||jsonb_build_array(candidate);
  end loop;
  return jsonb_build_object('candidate_ids',saved);
end;
$$;
create or replace function public.save_mt_room_candidate(target_project_id uuid,target_business_id uuid,target_offering_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result:=public.save_mt_room_candidates(target_project_id,target_business_id,array[target_offering_id]);
  return (result->'candidate_ids'->>0)::uuid;
end;
$$;
revoke all on function public.save_mt_room_candidates(uuid,uuid,uuid[]),public.save_mt_room_candidate(uuid,uuid,uuid) from public,anon;
grant execute on function public.save_mt_room_candidates(uuid,uuid,uuid[]),public.save_mt_room_candidate(uuid,uuid,uuid) to authenticated;

create or replace function public.toggle_mt_room_budget(target_project_id uuid,target_offering_id uuid,include_room boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare project public.mt_projects%rowtype; room public.offerings%rowtype; base integer; item public.mt_project_items%rowtype;
begin
  select * into project from public.mt_projects p where p.id=target_project_id and public.can_edit_mt_project(p.id) for update;
  if auth.uid() is null or project.id is null or project.status in ('completed','cancelled') then raise exception '수정 가능한 MT가 아닙니다.'; end if;
  if include_room then
    select o.* into room from public.offerings o join public.mt_project_candidates c on c.offering_id=o.id
      join public.businesses b on b.id=o.business_id
      where c.project_id=project.id and o.id=target_offering_id and o.is_active
      and b.business_type='stay' and b.approval_status='approved';
    if room.id is null or not public.stay_range_is_available(room.id,project.starts_on,project.ends_on) then
      raise exception '후보 객실의 공실을 다시 확인해주세요.';
    end if;
    base:=public.calculate_stay_base_amount(room.id,project.starts_on,project.ends_on);
    select * into item from public.mt_project_items i where i.project_id=project.id and i.item_kind='stay'
      and i.reference_id=room.id order by i.created_at limit 1;
    if item.id is null then
      insert into public.mt_project_items(project_id,item_kind,reference_id,title,quantity,amount,status,note)
      values(project.id,'stay',room.id,room.name,1,base,'planned','객실 기본금액. 추가 인원·부대시설 별도 확인.') returning * into item;
    else
      update public.mt_project_items set amount=base,quantity=1,status='planned' where id=item.id returning * into item;
    end if;
    return to_jsonb(item);
  end if;
  delete from public.mt_project_items i where i.project_id=project.id and i.item_kind='stay' and i.reference_id=target_offering_id;
  return '{}'::jsonb;
end;
$$;
revoke all on function public.toggle_mt_room_budget(uuid,uuid,boolean) from public,anon;
grant execute on function public.toggle_mt_room_budget(uuid,uuid,boolean) to authenticated;

create or replace function public.add_mt_shopping_candidate(target_project_id uuid,target_offering_id uuid,requested_quantity integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare project public.mt_projects%rowtype; product public.offerings%rowtype; item public.mt_project_items%rowtype;
  minimum integer; step_size integer; next_quantity integer;
begin
  select * into project from public.mt_projects p where p.id=target_project_id and public.can_edit_mt_project(p.id) for update;
  if auth.uid() is null or project.id is null or project.status in ('completed','cancelled') then raise exception '수정 가능한 MT가 아닙니다.'; end if;
  select o.* into product from public.offerings o join public.businesses b on b.id=o.business_id
    where o.id=target_offering_id and o.is_active and b.business_type='market' and b.approval_status='approved';
  if product.id is null then raise exception '이용 가능한 상품을 선택해주세요.'; end if;
  minimum:=greatest(1,coalesce((product.detail_sections->>'minimumOrderQuantity')::integer,1));
  step_size:=greatest(1,coalesce((product.detail_sections->>'quantityStep')::integer,1));
  if requested_quantity is null or requested_quantity<minimum or requested_quantity>1000 or (requested_quantity-minimum)%step_size<>0 then
    raise exception '상품의 최소 주문량과 수량 단위를 확인해주세요.';
  end if;
  select * into item from public.mt_project_items i where i.project_id=project.id and i.item_kind='shopping'
    and i.reference_id=product.id and i.status<>'cancelled' order by i.created_at limit 1;
  next_quantity:=requested_quantity+coalesce(item.quantity,0);
  if next_quantity>1000 then raise exception '한 상품의 후보 수량은 최대 1,000개입니다.'; end if;
  if item.id is null then
    insert into public.mt_project_items(project_id,item_kind,reference_id,title,quantity,amount,status)
    values(project.id,'shopping',product.id,coalesce(nullif(product.detail_sections->>'productDisplayName',''),product.name),requested_quantity,product.price,'planned') returning * into item;
  else
    update public.mt_project_items set quantity=next_quantity,amount=product.price where id=item.id returning * into item;
  end if;
  return to_jsonb(item);
end;
$$;
revoke all on function public.add_mt_shopping_candidate(uuid,uuid,integer) from public,anon;
grant execute on function public.add_mt_shopping_candidate(uuid,uuid,integer) to authenticated;
create or replace function public.remove_mt_room_candidate(target_project_id uuid,target_offering_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare project public.mt_projects%rowtype;
begin
  select * into project from public.mt_projects p where p.id=target_project_id and public.can_edit_mt_project(p.id) for update;
  if auth.uid() is null or project.id is null or project.status in ('completed','cancelled') then raise exception '수정 가능한 MT가 아닙니다.'; end if;
  delete from public.mt_project_items i where i.project_id=project.id and i.item_kind='stay' and i.reference_id=target_offering_id;
  delete from public.mt_project_candidates c where c.project_id=project.id and c.offering_id=target_offering_id;
end;
$$;
revoke all on function public.remove_mt_room_candidate(uuid,uuid) from public,anon;
grant execute on function public.remove_mt_room_candidate(uuid,uuid) to authenticated;
commit;
