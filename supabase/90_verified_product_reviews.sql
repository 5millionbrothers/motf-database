-- Product reviews never replace or relabel existing merchant-level reviews.
begin;
create table if not exists public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.market_orders(id),
  offering_id uuid not null references public.offerings(id),
  author_id uuid not null references public.profiles(id),
  rating numeric(2,1) not null check(rating>=1 and rating<=5),
  body text not null check(length(btrim(body)) between 2 and 2000),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id,offering_id)
);
alter table public.product_reviews enable row level security;
create index if not exists product_reviews_public_offering_date on public.product_reviews(offering_id,created_at desc) where not is_hidden;
revoke all on public.product_reviews from public,anon,authenticated;
grant select,update on public.product_reviews to authenticated;
grant all on public.product_reviews to service_role;
drop policy if exists product_reviews_admin_read on public.product_reviews;
create policy product_reviews_admin_read on public.product_reviews for select to authenticated using(public.is_admin() or author_id=auth.uid());
drop policy if exists product_reviews_admin_moderate on public.product_reviews;
create policy product_reviews_admin_moderate on public.product_reviews for update to authenticated using(public.is_admin()) with check(public.is_admin());

create or replace function public.get_public_product_review_summaries()
returns table(offering_id uuid,average_rating_5 numeric,review_count bigint)
language sql stable security definer set search_path='' as $$
  select r.offering_id,round(avg(r.rating),1),count(*) from public.product_reviews r
  join public.offerings o on o.id=r.offering_id join public.businesses b on b.id=o.business_id
  where not r.is_hidden and o.is_active and b.approval_status='approved' group by r.offering_id;
$$;
create or replace function public.get_public_product_reviews(target_offering_id uuid,result_limit integer default 50)
returns table(id uuid,rating numeric,body text,author_name text,created_at timestamptz)
language sql stable security definer set search_path='' as $$
  select r.id,r.rating,r.body,'이용 완료 고객'::text,r.created_at from public.product_reviews r
  join public.offerings o on o.id=r.offering_id join public.businesses b on b.id=o.business_id
  where r.offering_id=target_offering_id and not r.is_hidden and o.is_active and b.approval_status='approved'
  order by r.created_at desc limit least(greatest(coalesce(result_limit,50),1),100);
$$;
create or replace function public.get_product_review_orders(target_offering_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'created_at',t.created_at,'review',(
    select jsonb_build_object('rating',r.rating,'body',r.body,'is_author',r.author_id=auth.uid()) from public.product_reviews r
    where r.order_id=t.id and r.offering_id=target_offering_id))) from (
    select o.id,o.created_at from public.market_orders o where o.status='completed' and
    (case when o.organization_id is not null then public.is_organization_member(o.organization_id) else o.customer_id=auth.uid() end)
    and exists(select 1 from public.market_order_items i where i.order_id=o.id and i.offering_id=target_offering_id)
    order by o.created_at desc limit 100) t),'[]'::jsonb);
end;
$$;
create or replace function public.save_product_review(target_order_id uuid,target_offering_id uuid,review_rating numeric,review_body text)
returns uuid language plpgsql security definer set search_path='' as $$
declare ord public.market_orders%rowtype; existing public.product_reviews%rowtype; result uuid;
begin
  select * into ord from public.market_orders o where o.id=target_order_id for update;
  if auth.uid() is null or ord.id is null or ord.status<>'completed' or not exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.status='approved' and p.withdrawal_processed_at is null)
    or not(case when ord.organization_id is not null then public.is_organization_member(ord.organization_id) else ord.customer_id=auth.uid() end)
    or not exists(select 1 from public.market_order_items i where i.order_id=ord.id and i.offering_id=target_offering_id) then
    raise exception '실제로 이용 완료한 주문의 상품만 리뷰를 작성할 수 있습니다.';
  end if;
  if review_rating is null or review_rating<1 or review_rating>5 or length(btrim(coalesce(review_body,''))) not between 2 and 2000 then
    raise exception '평점과 2~2,000자의 리뷰를 입력해주세요.';
  end if;
  select * into existing from public.product_reviews r where r.order_id=ord.id and r.offering_id=target_offering_id;
  if existing.id is not null and existing.author_id<>auth.uid() then raise exception '이 주문의 상품 리뷰는 이미 다른 담당자가 작성했습니다.'; end if;
  insert into public.product_reviews(order_id,offering_id,author_id,rating,body)
    values(ord.id,target_offering_id,auth.uid(),review_rating,btrim(review_body))
    on conflict(order_id,offering_id) do update set rating=excluded.rating,body=excluded.body,updated_at=now()
    returning id into result;
  return result;
end;
$$;
revoke all on function public.get_public_product_review_summaries(),public.get_public_product_reviews(uuid,integer) from public;
grant execute on function public.get_public_product_review_summaries(),public.get_public_product_reviews(uuid,integer) to anon,authenticated;
revoke all on function public.get_product_review_orders(uuid),public.save_product_review(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.get_product_review_orders(uuid),public.save_product_review(uuid,uuid,numeric,text) to authenticated;
commit;
notify pgrst, 'reload schema';
