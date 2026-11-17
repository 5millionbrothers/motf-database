-- Site contact forms share the existing admin support inbox. No public case reads.
begin;

alter table public.support_cases
  add column if not exists contact_source text,
  add column if not exists contact_details jsonb not null default '{}'::jsonb,
  add column if not exists contact_consent_at timestamptz;

create table if not exists public.site_contact_receipts (
  request_id uuid primary key,
  ip_hash text not null check (ip_hash ~ '^[a-f0-9]{64}$'),
  request_digest text not null check (request_digest ~ '^[a-f0-9]{64}$'),
  support_case_id uuid not null references public.support_cases(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists site_contact_receipts_rate_idx
  on public.site_contact_receipts(ip_hash, created_at desc);
alter table public.site_contact_receipts enable row level security;
revoke all on public.site_contact_receipts from public, anon, authenticated;

-- Existing signed-in inquiries remain supported, but cannot forge site-form metadata.
drop policy if exists support_case_user_insert on public.support_cases;
create policy support_case_user_insert on public.support_cases
  for insert to authenticated with check (
    reporter_id = auth.uid() and contact_source is null
    and contact_details = '{}'::jsonb and contact_consent_at is null
  );

create or replace function public.submit_site_contact(
  request_key uuid, request_ip_hash text, request_digest text,
  form_source text, form_details jsonb, message_body text
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  receipt public.site_contact_receipts%rowtype;
  case_id uuid;
  contact_value text := trim(coalesce(form_details->>'contact', ''));
begin
  if request_key is null or request_ip_hash !~ '^[a-f0-9]{64}$'
     or request_digest !~ '^[a-f0-9]{64}$'
     or request_ip_hash is null or request_digest is null then
    raise exception '잘못된 접수 요청입니다.' using errcode = '22023';
  end if;
  if form_source is null or form_source not in ('partner', 'feedback')
     or jsonb_typeof(form_details) is distinct from 'object'
     or length(trim(coalesce(message_body, ''))) not between 5 and 5000
     or length(contact_value) > 150
     or exists (select 1 from jsonb_each_text(form_details) d where length(d.value) > 150)
     or exists (select 1 from jsonb_object_keys(form_details) k
       where k not in ('contact', 'contactName', 'businessName', 'businessType', 'topic')) then
    raise exception '문의 내용을 확인해주세요.' using errcode = '22023';
  end if;
  if form_source = 'partner' and (
    length(trim(coalesce(form_details->>'contactName', ''))) not between 1 and 80
    or length(trim(coalesce(form_details->>'businessName', ''))) not between 1 and 100
    or coalesce(form_details->>'businessType', '') not in ('숙소', '식당·식자재', '레크리에이션·체험', '교통', '기타')
    or contact_value = ''
  ) then
    raise exception '업장과 담당자 연락처를 확인해주세요.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('site_contact:' || request_key::text, 0));
  select * into receipt from public.site_contact_receipts where request_id = request_key;
  if found then
    if receipt.ip_hash <> request_ip_hash or receipt.request_digest <> request_digest then
      raise exception '이미 사용된 접수 요청입니다.' using errcode = '22023';
    end if;
    return receipt.support_case_id;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('site_contact_rate:' || request_ip_hash, 0));
  if (select count(*) from public.site_contact_receipts
      where ip_hash = request_ip_hash and created_at > now() - interval '15 minutes') >= 5
     or (select count(*) from public.site_contact_receipts
      where ip_hash = request_ip_hash and created_at > now() - interval '1 day') >= 20 then
    raise exception '접수 요청이 많습니다. 잠시 후 다시 시도해주세요.' using errcode = 'P0429';
  end if;
  insert into public.support_cases(case_type, title, body, contact_source, contact_details, contact_consent_at)
  values ('inquiry', case when form_source = 'partner' then '신규 입점 문의 · ' || trim(form_details->>'businessName')
    else '유저 건의사항 · ' || coalesce(nullif(form_details->>'topic', ''), '기타 의견') end,
    trim(message_body), form_source, form_details, now()) returning id into case_id;
  insert into public.site_contact_receipts(request_id, ip_hash, request_digest, support_case_id)
    values(request_key, request_ip_hash, request_digest, case_id);
  return case_id;
end;
$$;
revoke all on function public.submit_site_contact(uuid, text, text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.submit_site_contact(uuid, text, text, text, jsonb, text) to service_role;
notify pgrst, 'reload schema';
commit;
