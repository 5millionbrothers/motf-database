-- 이용자 회원 탈퇴 처리.
-- 거래/정산 기록은 보존하고, 진행 중인 건이 없을 때 개인정보 일부와 이메일을 익명화합니다.
-- Auth 이메일 변경은 Vercel 서버 API에서 service role key로 처리합니다.

alter table public.profiles
  add column if not exists withdrawal_requested_at timestamptz,
  add column if not exists withdrawal_processed_at timestamptz,
  add column if not exists withdrawal_reason text,
  add column if not exists withdrawal_anonymized_email text;

drop function if exists public.request_account_withdrawal(text);
create or replace function public.request_account_withdrawal(
  request_reason text default null,
  anonymized_email text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_count integer;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select
    (
      select count(*)
      from public.reservations r
      where r.customer_id = auth.uid()
        and r.status in ('pending', 'confirmed')
    ) +
    (
      select count(*)
      from public.market_orders o
      where o.customer_id = auth.uid()
        and o.status in ('pending', 'confirmed')
    ) +
    (
      select count(*)
      from public.payment_intents pi
      where pi.customer_id = auth.uid()
        and pi.status in ('prepared', 'virtual_account_issued')
        and coalesce(
          pi.expires_at,
          pi.virtual_account_issued_at + interval '24 hours',
          pi.created_at + interval '30 minutes'
        ) > now()
    )
  into active_count;

  if active_count > 0 then
    raise exception '진행 중인 예약, 주문, 입금 대기 건이 있어 탈퇴 요청을 처리할 수 없습니다. 고객센터에 문의해주세요.';
  end if;

  update public.profiles
  set
    status = 'suspended',
    email = coalesce(nullif(trim(anonymized_email), ''), email),
    full_name = '탈퇴 회원',
    phone = null,
    organization = null,
    withdrawal_requested_at = now(),
    withdrawal_processed_at = now(),
    withdrawal_reason = nullif(trim(request_reason), ''),
    withdrawal_anonymized_email = nullif(trim(anonymized_email), ''),
    updated_at = now()
  where id = auth.uid()
    and role = 'user';

  if not found then
    raise exception '탈퇴 요청은 일반 이용자 계정에서만 가능합니다.';
  end if;

  update public.conversations
  set
    customer_name = '탈퇴 회원',
    group_name = null
  where customer_id = auth.uid();
end;
$$;

revoke all on function public.request_account_withdrawal(text, text) from public;
grant execute on function public.request_account_withdrawal(text, text) to authenticated;
