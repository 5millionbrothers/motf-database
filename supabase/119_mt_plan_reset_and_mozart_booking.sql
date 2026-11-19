begin;

create or replace function public.reset_mt_project_plan(target_project_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  perform 1 from public.mt_projects p
  where p.id=target_project_id and p.launch_archived_at is null
    and p.status not in ('completed','cancelled') and public.can_edit_mt_project(p.id)
  for update;
  if not found then raise exception '초기화할 수 있는 MT가 아닙니다.'; end if;

  delete from public.mt_project_items where project_id=target_project_id and status='planned';
  delete from public.mt_project_candidates where project_id=target_project_id;
end;
$$;
revoke all on function public.reset_mt_project_plan(uuid) from public,anon;
grant execute on function public.reset_mt_project_plan(uuid) to authenticated;

create or replace function public.stay_price_for_date(target_offering_id uuid, target_date date)
returns integer language plpgsql stable security definer set search_path='' as $$
declare
  room public.offerings%rowtype;
  season_name text;
  weekend boolean;
  nightly integer;
  mozart_id constant uuid := '50e5c710-3310-4eaa-8f09-9f7c768ff066';
begin
  select * into room from public.offerings where id=target_offering_id and is_active and retired_at is null;
  if room.id is null then raise exception '객실을 찾을 수 없습니다.'; end if;
  season_name := public.stay_season_for_date(room.business_id,target_date);
  -- The A/B variants label Saturday as the only weekend night. Other rooms keep their regular rates.
  if room.business_id=mozart_id and room.id in (
    '5667ef8e-e75c-455f-88c3-caa00a556054', 'f1fcc0a1-9e7d-4604-a249-bf5692175d41',
    '28b1ade5-1d61-4f15-9c24-8ae915f79dd2', 'aef1a0d3-fede-4c8f-8066-ec5928f3a961'
  ) then
    weekend := extract(isodow from target_date)=6;
  else
    weekend := extract(isodow from target_date) in (5,6);
  end if;
  nightly := greatest(coalesce(case
    when season_name='peak' and weekend then room.peak_weekend_price
    when season_name='peak' then room.peak_weekday_price
    when season_name='shoulder' and weekend then room.shoulder_weekend_price
    when season_name='shoulder' then room.shoulder_weekday_price
    when weekend then room.offseason_weekend_price
    else room.offseason_weekday_price
  end,room.price,0),0);
  if room.business_id=mozart_id and nightly=999999 then
    raise exception '선택한 날짜에는 이 객실을 예약할 수 없습니다.';
  end if;
  return nightly;
end;
$$;

-- Already-open payment windows must not approve an unusable day or an old quote.
create or replace function public.check_mozart_checkout_quote(target_intent_id uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare
  intent public.payment_intents%rowtype;
  start_on date;
  end_on date;
begin
  select * into intent from public.payment_intents where id=target_intent_id
    and kind='stay' and draft->>'business_id'='50e5c710-3310-4eaa-8f09-9f7c768ff066';
  if not found then return false; end if;
  start_on := coalesce(nullif(intent.draft->>'check_in_date',''),intent.draft->>'event_date')::date;
  end_on := coalesce(nullif(intent.draft->>'check_out_date','')::date,start_on+1);
  return coalesce(intent.original_amount=public.calculate_stay_base_amount((intent.draft->>'offering_id')::uuid,start_on,end_on),false);
exception when raise_exception then return false;
end;
$$;
revoke all on function public.check_mozart_checkout_quote(uuid) from public,anon,authenticated;
grant execute on function public.check_mozart_checkout_quote(uuid) to service_role;

notify pgrst,'reload schema';
commit;
