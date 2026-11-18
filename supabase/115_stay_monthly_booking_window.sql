begin;

create or replace function public.stay_booking_window_end(as_of timestamptz default now())
returns date language sql stable set search_path='' as $$
  select (date_trunc('month',as_of at time zone 'Asia/Seoul') + interval '4 months')::date;
$$;

create or replace function public.guard_stay_booking_window()
returns trigger language plpgsql set search_path='' as $$
declare check_in date; check_out date; limit_date date; open_date date;
begin
  if new.kind<>'stay' then return new; end if;
  if tg_op='UPDATE' and new.kind is not distinct from old.kind
      and row(new.draft->>'check_in_date',new.draft->>'event_date',new.draft->>'check_out_date') is not distinct from
          row(old.draft->>'check_in_date',old.draft->>'event_date',old.draft->>'check_out_date') then
    return new;
  end if;
  check_in:=coalesce(nullif(new.draft->>'check_in_date',''),nullif(new.draft->>'event_date',''))::date;
  check_out:=coalesce(nullif(new.draft->>'check_out_date','')::date,check_in+1);
  if check_in is null or check_out is null or not isfinite(check_in) or not isfinite(check_out)
      or check_in<(now() at time zone 'Asia/Seoul')::date or check_in>=check_out then
    raise exception '숙박 일정을 다시 확인해주세요.';
  end if;
  limit_date:=public.stay_booking_window_end();
  if check_out>limit_date then
    open_date:=(date_trunc('month',(check_out-1)::timestamp)-interval '3 months')::date;
    raise exception '선택한 일정은 % 한국시간 00:00에 예약이 열립니다. (숙박하는 모든 날짜가 열려야 예약할 수 있습니다.)',open_date;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_stay_booking_window on public.payment_intents;
create trigger guard_stay_booking_window before insert or update of kind,draft on public.payment_intents
for each row execute function public.guard_stay_booking_window();

-- This obsolete pre-checkout RPC is unused by both apps and bypasses checkout/inventory.
revoke execute on function public.create_reservation(uuid,uuid,text,text,text,date,integer,text)
  from public,anon,authenticated;

commit;
