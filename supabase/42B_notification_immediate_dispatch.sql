-- moTF notification immediate dispatch.
-- When a queued notification is inserted, Supabase calls the Vercel dispatch API immediately.
-- The 5-minute Vercel Cron remains as a safety net for missed or retryable notifications.

create extension if not exists pg_net;
create extension if not exists supabase_vault cascade;

create or replace function public.notification_dispatch_secret(secret_name text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret
  from vault.decrypted_secrets
  where name = secret_name
  order by created_at desc
  limit 1;
$$;

create table if not exists public.notification_dispatch_pings (
  id bigserial primary key,
  outbox_id uuid references public.notification_outbox(id) on delete set null,
  request_id bigint,
  dispatch_url text not null,
  source text not null default 'notification_outbox_trigger',
  created_at timestamptz not null default now()
);

alter table public.notification_dispatch_pings enable row level security;

drop policy if exists "notification_dispatch_pings_admin_read" on public.notification_dispatch_pings;
create policy "notification_dispatch_pings_admin_read"
on public.notification_dispatch_pings for select to authenticated
using (public.is_admin());

grant select on public.notification_dispatch_pings to authenticated;

create or replace function public.dispatch_notification_outbox_now()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  dispatch_url text;
  dispatch_secret text;
  request_id bigint;
begin
  if new.status <> 'queued' then
    return new;
  end if;

  if new.next_attempt_at > now() then
    return new;
  end if;

  dispatch_secret := public.notification_dispatch_secret('motf_notification_dispatch_secret');
  dispatch_url := coalesce(
    nullif(public.notification_dispatch_secret('motf_notification_dispatch_url'), ''),
    'https://motf.co.kr/api/notifications-dispatch'
  );

  if nullif(trim(coalesce(dispatch_secret, '')), '') is null then
    return new;
  end if;

  select net.http_post(
    url := dispatch_url,
    body := jsonb_build_object(
      'limit', 20,
      'source', 'notification_outbox_trigger',
      'outboxId', new.id::text
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-notification-secret', dispatch_secret
    ),
    timeout_milliseconds := 2000
  ) into request_id;

  insert into public.notification_dispatch_pings (
    outbox_id,
    request_id,
    dispatch_url,
    source
  ) values (
    new.id,
    request_id,
    dispatch_url,
    'notification_outbox_trigger'
  );

  return new;
exception
  when others then
    -- Do not block the business event. The 5-minute Cron will retry queued notifications.
    return new;
end;
$$;

drop trigger if exists notification_outbox_immediate_dispatch_insert on public.notification_outbox;
create trigger notification_outbox_immediate_dispatch_insert
after insert on public.notification_outbox
for each row
when (new.status = 'queued')
execute function public.dispatch_notification_outbox_now();

drop trigger if exists notification_outbox_immediate_dispatch_requeue on public.notification_outbox;
create trigger notification_outbox_immediate_dispatch_requeue
after update of status, next_attempt_at on public.notification_outbox
for each row
when (
  new.status = 'queued'
  and old.status is distinct from new.status
)
execute function public.dispatch_notification_outbox_now();

revoke all on function public.notification_dispatch_secret(text) from public;
revoke all on function public.dispatch_notification_outbox_now() from public;

grant execute on function public.notification_dispatch_secret(text) to service_role;

