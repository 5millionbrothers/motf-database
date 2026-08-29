-- Fix post-signup identity attachment, business verification and MOriginal media.

grant usage on schema public to service_role;
grant select, insert, update, delete on table public.profiles to service_role;
grant select, insert, update, delete on table public.businesses to service_role;

create or replace function public.complete_verified_user_profile(
  profile_organization text,
  password_was_set boolean default false
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  completed_profile public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if nullif(trim(profile_organization), '') is null then
    raise exception '학교/소속을 입력해주세요.';
  end if;

  update public.profiles
  set organization = trim(profile_organization),
      password_set_at = case
        when password_was_set then coalesce(password_set_at, now())
        else password_set_at
      end,
      profile_completed_at = now(),
      updated_at = now()
  where id = auth.uid()
    and identity_verified_at is not null
  returning * into completed_profile;

  if completed_profile.id is null then
    raise exception '휴대폰 본인인증을 먼저 완료해주세요.';
  end if;

  return completed_profile;
end;
$$;

revoke all on function public.complete_verified_user_profile(text,boolean) from public;
grant execute on function public.complete_verified_user_profile(text,boolean) to authenticated;

alter table public.platform_events
  add column if not exists promo_video_url text;

comment on column public.platform_events.promo_video_url is
  'Optional external promotional video URL shown on the MOriginal detail page';

create or replace function public.get_public_review_summaries()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', summary.business_id,
    'review_count', summary.review_count,
    'average_rating_5', summary.average_rating_5
  )), '[]'::jsonb)
  from (
    select
      r.business_id,
      count(*)::integer as review_count,
      round((avg(r.rating)::numeric / 2), 1) as average_rating_5
    from public.reviews r
    join public.businesses b on b.id = r.business_id
    where coalesce(r.is_hidden, false) = false
      and b.approval_status = 'approved'
    group by r.business_id
  ) summary;
$$;

revoke all on function public.get_public_review_summaries() from public;
grant execute on function public.get_public_review_summaries() to anon, authenticated;
