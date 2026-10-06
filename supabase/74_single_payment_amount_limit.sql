-- moTF launch risk control: no single payment may exceed KRW 10,000,000.

create or replace function public.enforce_single_payment_amount_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.amount > 10000000
     or coalesce(new.original_amount, new.amount) > 10000000 then
    raise exception using
      errcode = '22003',
      message = '단건 결제는 10,000,000원까지 가능합니다. 숙박 일정이나 주문 수량을 조정해주세요.';
  end if;
  return new;
end;
$$;

drop trigger if exists payment_intents_single_amount_limit on public.payment_intents;
create trigger payment_intents_single_amount_limit
before insert or update of amount, original_amount on public.payment_intents
for each row execute function public.enforce_single_payment_amount_limit();

-- Add a hard constraint when historical data already satisfies the limit.
-- If an old over-limit test intent exists, the trigger still protects every new or repriced intent.
do $$
begin
  if not exists (
    select 1
    from public.payment_intents
    where amount > 10000000
       or coalesce(original_amount, amount) > 10000000
  ) and not exists (
    select 1
    from pg_constraint
    where conname = 'payment_intents_single_amount_limit_check'
      and conrelid = 'public.payment_intents'::regclass
  ) then
    alter table public.payment_intents
      add constraint payment_intents_single_amount_limit_check
      check (amount <= 10000000 and coalesce(original_amount, amount) <= 10000000);
  end if;
end;
$$;

comment on function public.enforce_single_payment_amount_limit() is
  'Blocks payment intents whose external or original single-payment amount exceeds KRW 10,000,000.';
