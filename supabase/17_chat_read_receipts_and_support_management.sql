-- moTF 5단계: 채팅 읽음 처리와 문의·분쟁 실제 관리

create index if not exists support_cases_status_created_idx
on public.support_cases(status, created_at desc);

create or replace function public.mark_conversation_read(
  target_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_conversation public.conversations%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into target_conversation
  from public.conversations
  where id = target_conversation_id;

  if target_conversation.id is null then
    raise exception '대화를 찾을 수 없습니다.';
  end if;

  if not (
    target_conversation.customer_id = auth.uid()
    or public.owns_business(target_conversation.business_id)
    or public.is_admin()
  ) then
    raise exception '이 대화를 확인할 권한이 없습니다.';
  end if;

  update public.messages
  set read_at = now()
  where conversation_id = target_conversation_id
    and sender_id <> auth.uid()
    and read_at is null;
end;
$$;

create or replace function public.review_support_case(
  target_case_id uuid,
  new_status text,
  note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  if new_status not in ('received', 'processing', 'resolved') then
    raise exception '올바르지 않은 문의 처리 상태입니다.';
  end if;

  update public.support_cases
  set
    status = new_status,
    admin_note = coalesce(note, admin_note),
    assigned_admin = auth.uid()
  where id = target_case_id;

  if not found then
    raise exception '문의 접수 건을 찾을 수 없습니다.';
  end if;
end;
$$;

revoke all on function public.mark_conversation_read(uuid) from public;
revoke all on function public.review_support_case(uuid, text, text) from public;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.review_support_case(uuid, text, text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'support_cases'
  ) then
    alter publication supabase_realtime add table public.support_cases;
  end if;
end;
$$;
