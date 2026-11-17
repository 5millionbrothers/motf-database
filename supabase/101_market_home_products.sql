-- Home recommendations are independent of catalog order and product review.
begin;
create table if not exists public.market_home_selections (
 business_id uuid primary key references public.businesses(id) on delete cascade,
 offering_ids uuid[] not null check(array_ndims(offering_ids)=1 and cardinality(offering_ids)=4 and array_position(offering_ids,null) is null),
 updated_at timestamptz not null default now(),
 updated_by uuid references public.profiles(id) on delete set null
);
alter table public.market_home_selections enable row level security;
revoke all on public.market_home_selections from public,anon,authenticated;
grant select on public.market_home_selections to authenticated;
drop policy if exists market_home_owner_read on public.market_home_selections;
create policy market_home_owner_read on public.market_home_selections for select to authenticated
 using(public.is_admin() or public.has_business_permission(business_id,'listing'));

create or replace function public.save_market_home_products(target_business_id uuid,product_ids uuid[],expected_updated_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare previous public.market_home_selections%rowtype; saved public.market_home_selections%rowtype; valid_count integer; group_count integer;
begin
 if auth.uid() is null or not (public.is_admin() or public.has_business_permission(target_business_id,'listing')) then raise exception '홈 추천 상품을 변경할 권한이 없습니다.'; end if;
 if not exists(select 1 from public.businesses where id=target_business_id and business_type='market') then raise exception '공판장 업장을 확인해주세요.'; end if;
 if coalesce(cardinality(product_ids),0)<>4 or array_ndims(product_ids)<>1 or array_position(product_ids,null) is not null
 or (select count(distinct id) from unnest(product_ids) id)<>4 then raise exception '서로 다른 상품 4개를 선택해주세요.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(target_business_id::text,101));
 select * into previous from public.market_home_selections where business_id=target_business_id for update;
 if previous.business_id is not null and previous.updated_at is distinct from expected_updated_at then raise exception '다른 담당자가 추천 상품을 수정했습니다. 다시 열어 확인해주세요.'; end if;
 select count(*),count(distinct case when nullif(btrim(o.detail_sections->>'productGroupKey'),'') is not null
 then 'configured:'||lower(regexp_replace(btrim(o.detail_sections->>'productGroupKey'),'\s+',' ','g'))
 else 'catalog:'||lower(regexp_replace(btrim(coalesce(nullif(o.detail_sections->>'productDisplayName',''),o.name)),'\s+',' ','g'))||':'||lower(regexp_replace(btrim(coalesce(o.detail_sections->>'manufacturer','')),'\s+',' ','g')) end)
 into valid_count,group_count from public.offerings o
 where o.id=any(product_ids) and o.business_id=target_business_id and o.is_active and o.retired_at is null
 and o.market_review_status='approved' and o.price>0 and (o.stock_quantity is null or o.stock_quantity>0);
 if valid_count<>4 or group_count<>4 then raise exception '판매 중인 승인 상품 4종을 선택해주세요. 같은 상품의 옵션을 중복 선택할 수 없습니다.'; end if;
 insert into public.market_home_selections(business_id,offering_ids,updated_by,updated_at)
 values(target_business_id,product_ids,auth.uid(),clock_timestamp())
 on conflict(business_id) do update set offering_ids=excluded.offering_ids,updated_by=excluded.updated_by,updated_at=excluded.updated_at returning * into saved;
 return jsonb_build_object('offering_ids',saved.offering_ids,'updated_at',saved.updated_at);
end;
$$;

create or replace function public.list_market_home_products()
returns table(business_id uuid,offering_ids uuid[]) language sql stable security definer set search_path='' as $$
 select s.business_id,coalesce(array_agg(o.id order by picked.position) filter(where o.id is not null),'{}'::uuid[])
 from public.market_home_selections s join public.businesses b on b.id=s.business_id and b.business_type='market' and b.approval_status='approved'
 cross join lateral unnest(s.offering_ids) with ordinality picked(id,position)
 left join public.offerings o on o.id=picked.id and o.business_id=s.business_id and o.is_active and o.retired_at is null
 and o.market_review_status='approved' and o.price>0 and (o.stock_quantity is null or o.stock_quantity>0)
 group by s.business_id;
$$;
revoke all on function public.save_market_home_products(uuid,uuid[],timestamptz),public.list_market_home_products() from public,anon,authenticated;
grant execute on function public.save_market_home_products(uuid,uuid[],timestamptz) to authenticated;
grant execute on function public.list_market_home_products() to anon,authenticated;

-- Only seed the current partner, and never replace a saved owner selection.
with defaults as (
 select b.id,array_agg(p.id order by kind.position) as ids
 from public.businesses b cross join (values(1,'삼겹'),(2,'목살'),(3,'참이슬'),(4,'테라')) kind(position,label)
 cross join lateral (
  select o.id from public.offerings o where o.business_id=b.id and o.is_active and o.retired_at is null and o.market_review_status='approved'
  and o.price>0 and (o.stock_quantity is null or o.stock_quantity>0)
  and coalesce(nullif(o.detail_sections->>'productDisplayName',''),o.name) like '%'||kind.label||'%'
  order by case when kind.position in (1,2) and concat_ws(' ',o.name,o.detail_sections->>'variantLabel',o.detail_sections->>'temperature') like '%냉동%' then 0
   when kind.position=3 and coalesce(o.detail_sections->>'productDisplayName',o.name) like '%후레쉬%' then 0 else 1 end,
   o.price,o.sort_order,o.id limit 1
 ) p
 where b.business_type='market' and b.business_name like '%대성%' group by b.id having count(*)=4
)
insert into public.market_home_selections(business_id,offering_ids) select id,ids from defaults on conflict(business_id) do nothing;
notify pgrst,'reload schema';
commit;
