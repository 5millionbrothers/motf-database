-- Relocating a recent save is atomic; failed moves leave the original intact.
begin;
create or replace function public.move_mt_recent_save(
  source_project_id uuid,target_project_id uuid,save_kind text,source_record_ids uuid[],
  move_quantity integer default null,expected_quantity integer default null,expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare source public.mt_projects%rowtype; target public.mt_projects%rowtype;
  item public.mt_project_items%rowtype; destination public.mt_project_items%rowtype;
  ids uuid[]; offering_ids uuid[]; new_offering_ids uuid[]; business uuid; result jsonb; total integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  -- A stable lock order also covers moves in opposite directions.
  perform 1 from public.mt_projects p where p.id in(source_project_id,target_project_id) order by p.id for update;
  select * into source from public.mt_projects p where p.id=source_project_id and public.can_edit_mt_project(p.id);
  select * into target from public.mt_projects p where p.id=target_project_id and public.can_edit_mt_project(p.id);
  if source.id is null or target.id is null or source.status in('completed','cancelled') or target.status in('completed','cancelled') then
    raise exception '수정 가능한 MT 사이에서만 저장 위치를 변경할 수 있습니다.';
  end if;
  if source.id=target.id then raise exception '다른 MT를 선택해주세요.'; end if;
  select array_agg(distinct x) into ids from unnest(source_record_ids) x where x is not null;
  if coalesce(cardinality(ids),0) not between 1 and 30 then raise exception '변경할 항목을 확인해주세요.'; end if;
  if save_kind='shopping' then
    if cardinality(ids)<>1 then raise exception '상품은 하나씩 변경해주세요.'; end if;
    select * into item from public.mt_project_items i where i.id=ids[1] and i.project_id=source.id and i.item_kind='shopping' and i.status='planned' for update;
    if item.id is null or item.quantity is distinct from expected_quantity or item.updated_at is distinct from expected_updated_at
      or move_quantity is null or move_quantity<1 or move_quantity>item.quantity then
      raise exception '담긴 수량이 변경되었습니다. 내 MT에서 확인 후 다시 시도해주세요.';
    end if;
    select * into destination from public.mt_project_items i where i.project_id=target.id and i.item_kind='shopping'
      and i.reference_id=item.reference_id and i.status<>'cancelled' order by i.created_at limit 1 for update;
    if destination.id is not null and destination.status<>'planned' then raise exception '이용 내역이 연결된 상품은 변경할 수 없습니다.'; end if;
    total:=coalesce(destination.quantity,0)+move_quantity;
    result:=public.set_mt_shopping_candidate(target.id,item.reference_id,total);
    if item.quantity=move_quantity then delete from public.mt_project_items i where i.id=item.id;
    else perform public.set_mt_shopping_candidate(source.id,item.reference_id,item.quantity-move_quantity); end if;
    return jsonb_build_object('save_reference',jsonb_build_object('kind','shopping','recordIds',jsonb_build_array(result->>'id'),
      'moveQuantity',move_quantity,'expectedQuantity',total,'updatedAt',result->'updated_at'));
  elsif save_kind='stay' then
    perform 1 from public.mt_project_candidates c where c.project_id=source.id and c.id=any(ids) for update;
    select array_agg(c.offering_id) into offering_ids from public.mt_project_candidates c where c.project_id=source.id and c.id=any(ids);
    if coalesce(cardinality(offering_ids),0)<>cardinality(ids) or array_position(offering_ids,null) is not null then raise exception '객실 후보가 변경되었습니다. 다시 확인해주세요.'; end if;
    if exists(select 1 from public.mt_project_items i where i.project_id=source.id and i.item_kind='stay' and i.reference_id=any(offering_ids)) then
      raise exception '예산에 반영된 객실입니다. 내 MT에서 예산 반영을 취소한 뒤 변경해주세요.';
    end if;
    if (select count(distinct c.business_id) from public.mt_project_candidates c where c.id=any(ids) and c.project_id=source.id)<>1 then raise exception '같은 숙소의 객실만 함께 변경할 수 있습니다.'; end if;
    select c.business_id into business from public.mt_project_candidates c where c.id=ids[1] and c.project_id=source.id;
    select array_agg(rid) into new_offering_ids from unnest(offering_ids) rid where not exists(
      select 1 from public.mt_project_candidates c where c.project_id=target.id and c.offering_id=rid);
    -- Validate every selected room against the destination dates, including an existing candidate.
    if exists(select 1 from unnest(offering_ids) rid where not public.stay_range_is_available(rid,target.starts_on,target.ends_on)) then
      raise exception '변경할 MT 일정에 예약할 수 없는 객실이 있습니다.';
    end if;
    if cardinality(new_offering_ids)>0 then result:=public.save_mt_room_candidates(target.id,business,new_offering_ids); end if;
    delete from public.mt_project_candidates c where c.project_id=source.id and c.id=any(ids);
    return jsonb_build_object('save_reference',case when cardinality(new_offering_ids)>0 then
      jsonb_build_object('kind','stay','recordIds',result->'candidate_ids') else null end);
  else raise exception '지원하지 않는 후보 유형입니다.';
  end if;
end;
$$;
revoke all on function public.move_mt_recent_save(uuid,uuid,text,uuid[],integer,integer,timestamptz) from public,anon;
grant execute on function public.move_mt_recent_save(uuid,uuid,text,uuid[],integer,integer,timestamptz) to authenticated;
commit;
notify pgrst,'reload schema';
