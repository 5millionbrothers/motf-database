-- Checkout identity enforcement, non-mutating benefit preview and admin-managed media.

update public.platform_settings
set setting_value = jsonb_build_object(
      'provider', 'kcp',
      'required_for_signup', true,
      'required_for_owner_signup', true
    ),
    description = 'KCP 휴대폰 본인확인은 회원가입과 결제 전에 필수',
    updated_at = now()
where setting_key = 'identity';

create or replace function public.enforce_verified_payment_customer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.customer_id is not null
     and new.kind in ('stay', 'market', 'extra_charge')
     and not exists (
       select 1
       from public.profiles p
       where p.id = new.customer_id
         and p.status = 'approved'
         and p.identity_verified_at is not null
     ) then
    raise exception '결제 전 휴대폰 본인인증이 필요합니다.';
  end if;
  return new;
end;
$$;

drop trigger if exists payment_intents_require_verified_customer on public.payment_intents;
create trigger payment_intents_require_verified_customer
before insert on public.payment_intents
for each row execute function public.enforce_verified_payment_customer();

create or replace function public.preview_checkout_benefits(
  target_original_amount integer,
  target_transaction_kind text,
  target_business_id uuid default null,
  requested_points integer default 0,
  requested_coupon_code text default null
)
returns table(
  original_amount integer,
  available_points integer,
  applied_points integer,
  applied_coupon_discount integer,
  payable_amount integer,
  coupon_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  account_balance integer := 0;
  held_points integer := 0;
  usable_points integer := 0;
  point_amount integer := 0;
  coupon_amount integer := 0;
  minimum_external integer := 100;
  selected_coupon public.coupons%rowtype;
  prior_uses integer := 0;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'approved' and p.identity_verified_at is not null
  ) then
    raise exception '결제 전 휴대폰 본인인증이 필요합니다.';
  end if;
  if target_original_amount is null or target_original_amount <= 0 then raise exception '주문 금액을 확인해주세요.'; end if;
  if target_transaction_kind not in ('stay', 'market') then raise exception '결제 종류를 확인해주세요.'; end if;

  minimum_external := coalesce((
    select (setting_value ->> 'minimum_external_amount')::integer
    from public.platform_settings where setting_key = 'payment'
  ), 100);

  select coalesce((
    select a.balance
    from public.point_accounts a
    where a.user_id = auth.uid()
  ), 0) into account_balance;
  select coalesce(sum(h.amount), 0) into held_points
  from public.point_holds h
  where h.user_id = auth.uid() and h.status = 'held' and h.expires_at > now();
  usable_points := greatest(account_balance - held_points, 0);

  if nullif(upper(trim(requested_coupon_code)), '') is not null then
    select * into selected_coupon
    from public.coupons c
    where upper(c.code) = upper(trim(requested_coupon_code))
      and c.is_active
      and now() between c.starts_at and c.ends_at
      and c.minimum_order_amount <= target_original_amount
      and c.applies_to in ('all', target_transaction_kind)
      and (c.business_id is null or c.business_id = target_business_id);
    if selected_coupon.id is null then raise exception '사용할 수 없는 할인코드입니다.'; end if;

    select count(*) into prior_uses
    from public.coupon_redemptions r
    where r.coupon_id = selected_coupon.id
      and r.user_id = auth.uid()
      and r.status in ('reserved', 'used');
    if prior_uses >= selected_coupon.per_user_limit then raise exception '할인코드 사용 가능 횟수를 초과했습니다.'; end if;
    if selected_coupon.total_usage_limit is not null and (
      select count(*) from public.coupon_redemptions r
      where r.coupon_id = selected_coupon.id and r.status in ('reserved', 'used')
    ) >= selected_coupon.total_usage_limit then
      raise exception '할인코드가 모두 소진되었습니다.';
    end if;

    coupon_amount := case when selected_coupon.discount_type = 'fixed'
      then selected_coupon.discount_value::integer
      else floor(target_original_amount * selected_coupon.discount_value / 100)::integer end;
    coupon_amount := least(
      coupon_amount,
      coalesce(selected_coupon.maximum_discount, coupon_amount),
      greatest(target_original_amount - minimum_external, 0)
    );
    if coupon_amount <= 0 then raise exception '이 주문에 적용할 할인금액이 없습니다.'; end if;
  end if;

  point_amount := least(
    greatest(coalesce(requested_points, 0), 0),
    usable_points,
    greatest(target_original_amount - coupon_amount - minimum_external, 0)
  );

  return query select
    target_original_amount,
    usable_points,
    point_amount,
    coupon_amount,
    target_original_amount - coupon_amount - point_amount,
    selected_coupon.name;
end;
$$;

revoke all on function public.preview_checkout_benefits(integer,text,uuid,integer,text) from public;
grant execute on function public.preview_checkout_benefits(integer,text,uuid,integer,text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'content-media',
  'content-media',
  true,
  20971520,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "content_media_public_read" on storage.objects;
create policy "content_media_public_read" on storage.objects
for select to public using (bucket_id = 'content-media');

drop policy if exists "content_media_admin_insert" on storage.objects;
create policy "content_media_admin_insert" on storage.objects
for insert to authenticated with check (bucket_id = 'content-media' and public.is_admin());

drop policy if exists "content_media_admin_update" on storage.objects;
create policy "content_media_admin_update" on storage.objects
for update to authenticated using (bucket_id = 'content-media' and public.is_admin())
with check (bucket_id = 'content-media' and public.is_admin());

drop policy if exists "content_media_admin_delete" on storage.objects;
create policy "content_media_admin_delete" on storage.objects
for delete to authenticated using (bucket_id = 'content-media' and public.is_admin());

drop policy if exists "community_admin_delete" on public.community_posts;
create policy "community_admin_delete" on public.community_posts
for delete to authenticated using (public.is_admin());
grant delete on public.community_posts to authenticated;

comment on function public.preview_checkout_benefits(integer,text,uuid,integer,text)
is 'Validates point/coupon use and returns a final amount without creating a payment intent or hold';
