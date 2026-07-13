-- moTF notification immediate dispatch secret setup.
-- Replace PASTE_NOTIFICATION_DISPATCH_SECRET_HERE with the same value used in Vercel NOTIFICATION_DISPATCH_SECRET.

create extension if not exists supabase_vault cascade;

do $$
declare
  -- Edit only this value. Use the exact same value as Vercel NOTIFICATION_DISPATCH_SECRET.
  dispatch_secret text := 'PASTE_SECRET_ONLY_HERE';
  existing_secret_id uuid;
  existing_url_id uuid;
begin
  if dispatch_secret in ('', 'PASTE_SECRET_ONLY_HERE')
     or length(trim(dispatch_secret)) < 16 then
    raise exception 'Replace only the dispatch_secret value with the real Vercel NOTIFICATION_DISPATCH_SECRET value first.';
  end if;

  select id into existing_secret_id
  from vault.decrypted_secrets
  where name = 'motf_notification_dispatch_secret'
  order by created_at desc
  limit 1;

  if existing_secret_id is null then
    perform vault.create_secret(
      dispatch_secret,
      'motf_notification_dispatch_secret',
      'Secret used by Supabase pg_net to invoke the moTF notification dispatch API.'
    );
  else
    perform vault.update_secret(
      existing_secret_id,
      dispatch_secret,
      'motf_notification_dispatch_secret',
      'Secret used by Supabase pg_net to invoke the moTF notification dispatch API.'
    );
  end if;

  select id into existing_url_id
  from vault.decrypted_secrets
  where name = 'motf_notification_dispatch_url'
  order by created_at desc
  limit 1;

  if existing_url_id is null then
    perform vault.create_secret(
      'https://motf.co.kr/api/notifications-dispatch',
      'motf_notification_dispatch_url',
      'moTF notification dispatch API endpoint.'
    );
  else
    perform vault.update_secret(
      existing_url_id,
      'https://motf.co.kr/api/notifications-dispatch',
      'motf_notification_dispatch_url',
      'moTF notification dispatch API endpoint.'
    );
  end if;
end $$;
