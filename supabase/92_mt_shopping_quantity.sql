-- Candidate quantities are absolute; this does not change orders or carts.
begin;
create or replace function public.set_mt_shopping_candidate(
  target_project_id uuid, target_offering_id uuid, requested_quantity integer
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare project public.mt_projects%rowtype; product public.offerings%rowtype;
  item public.mt_project_items%rowtype; minimum integer; step_size integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select * into project from public.mt_projects p
    where p.id=target_project_id and public.can_edit_mt_project(p.id) for update;
  if project.id is null or project.status in ('completed','cancelled') then raise exception '수정 가능한 MT가 아닙니다.'; end if;
  if requested_quantity is null or requested_quantity<0 or requested_quantity>1000 then raise exception '수량은 0~1,000개로 입력해주세요.'; end if;
  if requested_quantity=0 then
    delete from public.mt_project_items i where i.project_id=project.id and i.item_kind='shopping' and i.reference_id=target_offering_id;
    return '{}'::jsonb;
  end if;
  select o.* into product from public.offerings o join public.businesses b on b.id=o.business_id
    where o.id=target_offering_id and o.is_active and b.business_type='market' and b.approval_status='approved';
  if product.id is null then raise exception '판매가 중단된 상품입니다. 후보에서 삭제하고 다시 선택해주세요.'; end if;
  minimum:=greatest(1,coalesce((product.detail_sections->>'minimumOrderQuantity')::integer,1));
  step_size:=greatest(1,coalesce((product.detail_sections->>'quantityStep')::integer,1));
  if requested_quantity<minimum or (requested_quantity-minimum)%step_size<>0 then raise exception '상품의 최소 수량과 수량 단위를 확인해주세요.'; end if;
  select * into item from public.mt_project_items i where i.project_id=project.id
    and i.item_kind='shopping' and i.reference_id=product.id and i.status<>'cancelled'
    order by i.created_at limit 1;
  if item.id is null then
    insert into public.mt_project_items(project_id,item_kind,reference_id,title,quantity,amount,status)
    values(project.id,'shopping',product.id,coalesce(nullif(product.detail_sections->>'productDisplayName',''),product.name),requested_quantity,product.price,'planned') returning * into item;
  else
    update public.mt_project_items set quantity=requested_quantity,amount=product.price where id=item.id returning * into item;
    delete from public.mt_project_items i where i.project_id=project.id and i.item_kind='shopping' and i.reference_id=product.id and i.id<>item.id;
  end if;
  return to_jsonb(item);
end;
$$;
revoke all on function public.set_mt_shopping_candidate(uuid,uuid,integer) from public,anon;
grant execute on function public.set_mt_shopping_candidate(uuid,uuid,integer) to authenticated;
commit;
