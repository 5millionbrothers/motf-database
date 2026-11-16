-- Desktop author controls and account-owned chat replies. No payment changes.
begin;
alter table public.community_posts add column if not exists deleted_at timestamptz;
alter table public.community_comments add column if not exists deleted_at timestamptz;
create index if not exists community_comments_parent_idx on public.community_comments(parent_comment_id);

create or replace function public.guard_community_comment_changes()
returns trigger language plpgsql security definer set search_path='' as $$
declare post_row public.community_posts%rowtype; parent_row public.community_comments%rowtype;
begin
  if auth.role()='service_role' or public.is_admin() then return new; end if;
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if tg_op='INSERT' then
    select * into post_row from public.community_posts p where p.id=new.post_id for update;
    if post_row.id is null or post_row.deleted_at is not null or post_row.is_hidden then raise exception '이 글에는 댓글을 작성할 수 없습니다.'; end if;
    if new.parent_comment_id is not null then
      select * into parent_row from public.community_comments c where c.id=new.parent_comment_id for update;
      if parent_row.id is null or parent_row.post_id<>new.post_id then raise exception '답글 대상을 확인해주세요.'; end if;
    end if;
    if new.user_id<>auth.uid() or new.deleted_at is not null then raise exception '작성 권한이 없습니다.'; end if;
  else
    if old.user_id<>auth.uid() or old.deleted_at is not null
      or new.user_id is distinct from old.user_id or new.post_id is distinct from old.post_id
      or new.parent_comment_id is distinct from old.parent_comment_id or new.id is distinct from old.id
      or new.created_at is distinct from old.created_at then raise exception '수정 권한이 없습니다.'; end if;
    if new.deleted_at is null and exists(select 1 from public.community_comments c where c.parent_comment_id=old.id) then
      raise exception '답글이 달린 댓글은 수정할 수 없습니다.';
    end if;
    if new.deleted_at is not null then new.body:='삭제된 댓글입니다.'; new.deleted_at:=now(); end if;
    new.updated_at:=now();
  end if;
  return new;
end;
$$;
drop trigger if exists guard_community_comment_changes on public.community_comments;
create trigger guard_community_comment_changes before insert or update on public.community_comments
for each row execute function public.guard_community_comment_changes();
drop policy if exists community_comments_own_delete on public.community_comments;
drop policy if exists community_comments_admin_delete on public.community_comments;
create policy community_comments_admin_delete on public.community_comments for delete to authenticated using(public.is_admin());

create or replace function public.get_my_community_activity()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(item order by created_at desc),'[]'::jsonb) from (
    select jsonb_build_object('id',p.id,'kind','post','title',p.title,'body',p.body,'board_key',p.board_key,
      'created_at',p.created_at,'reply_count',(select count(*) from public.community_comments c where c.post_id=p.id)) item,p.created_at
      from public.community_posts p where p.author_id=auth.uid() and p.deleted_at is null
    union all
    select jsonb_build_object('id',c.id,'kind','comment','title',p.title,'body',c.body,'post_id',c.post_id,'board_key',p.board_key,
      'created_at',c.created_at,'reply_count',(select count(*) from public.community_comments child where child.parent_comment_id=c.id)),c.created_at
      from public.community_comments c join public.community_posts p on p.id=c.post_id where c.user_id=auth.uid() and c.deleted_at is null
    union all
    select jsonb_build_object('id',s.id,'kind','submission','title',s.title,'body',s.instructions,'created_at',s.created_at,
      'status',case s.review_status when 'pending' then '검토 중' when 'approved' then '승인' else '반려' end),s.created_at
      from public.recreation_submissions s where s.submitted_by=auth.uid()
    order by created_at desc limit 200
  ) activity;
$$;

create or replace function public.manage_my_community_item(item_type text,item_id uuid,operation text,new_title text default '',new_body text default '')
returns void language plpgsql security definer set search_path='' as $$
declare p public.community_posts%rowtype; c public.community_comments%rowtype;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if operation is null or operation not in('edit','delete') then raise exception '지원하지 않는 작업입니다.'; end if;
  if item_type='post' then
    select * into p from public.community_posts x where x.id=item_id for update;
    if p.id is null or p.author_id is distinct from auth.uid() or p.deleted_at is not null then raise exception '작성한 글만 관리할 수 있습니다.'; end if;
    if operation='edit' then
      if exists(select 1 from public.community_comments x where x.post_id=item_id) then raise exception '댓글이 달린 글은 수정할 수 없습니다.'; end if;
      if char_length(trim(new_title)) not between 1 and 100 or char_length(trim(new_body)) not between 1 and 10000 then raise exception '제목과 내용을 확인해주세요.'; end if;
      update public.community_posts set title=trim(new_title),body=trim(new_body) where id=item_id;
    else
      update public.community_posts set title='작성자가 삭제한 글입니다.',body='작성자가 삭제한 글입니다.',media_urls='{}',deleted_at=now() where id=item_id;
    end if;
  elsif item_type='comment' then
    select * into c from public.community_comments x where x.id=item_id for update;
    if c.id is null or c.user_id is distinct from auth.uid() or c.deleted_at is not null then raise exception '작성한 댓글만 관리할 수 있습니다.'; end if;
    if operation='edit' then
      if exists(select 1 from public.community_comments x where x.parent_comment_id=item_id) then raise exception '답글이 달린 댓글은 수정할 수 없습니다.'; end if;
      if char_length(trim(new_body)) not between 1 and 2000 then raise exception '댓글 내용을 확인해주세요.'; end if;
      update public.community_comments set body=trim(new_body),updated_at=now() where id=item_id;
    else
      update public.community_comments set body='삭제된 댓글입니다.',deleted_at=now(),updated_at=now() where id=item_id;
    end if;
  else raise exception '지원하지 않는 작성 유형입니다.';
  end if;
end;
$$;
revoke all on function public.get_my_community_activity() from public,anon;
revoke all on function public.manage_my_community_item(text,uuid,text,text,text) from public,anon;
grant execute on function public.get_my_community_activity(),public.manage_my_community_item(text,uuid,text,text,text) to authenticated;

create table if not exists public.chat_reply_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  title text not null check(char_length(trim(title)) between 1 and 30),
  body text not null check(char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.chat_reply_templates enable row level security;
drop policy if exists chat_reply_templates_own on public.chat_reply_templates;
create policy chat_reply_templates_own on public.chat_reply_templates for all to authenticated
using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select,insert,update,delete on public.chat_reply_templates to authenticated,service_role;
create index if not exists chat_reply_templates_user_idx on public.chat_reply_templates(user_id,created_at);
drop trigger if exists chat_reply_templates_updated_at on public.chat_reply_templates;
create trigger chat_reply_templates_updated_at before update on public.chat_reply_templates
for each row execute function public.set_updated_at();
commit;
