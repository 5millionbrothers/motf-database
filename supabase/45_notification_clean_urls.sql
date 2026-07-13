-- Generate clean public URLs for notification buttons.
-- Existing app code still accepts the old ?route= links, but new outbox rows should use clean paths.

create or replace function public.notification_user_url(path text default '')
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  base_url constant text := 'https://motf.co.kr';
  raw_path text := coalesce(path, '');
  query_text text;
  route_match text[];
  route_name text;
  rest_query text;
  target_path text;
begin
  if raw_path = '' or raw_path = '/' then
    return base_url;
  end if;

  if raw_path like '/?%' then
    query_text := substring(raw_path from 3);
    route_match := regexp_match(query_text, '(^|&)route=([^&]+)');
    route_name := coalesce(route_match[2], '');
    rest_query := trim(both '&' from regexp_replace(query_text, '(^|&)route=[^&]*&?', '', 'g'));

    target_path := case route_name
      when 'myUsage' then '/mypage/usage'
      when 'myAccount' then '/mypage/account'
      when 'myGuide' then '/mypage/guide'
      when 'mySupport' then '/mypage'
      when 'budgetPreview' then '/mypage/budget'
      when 'review' then '/mypage/review'
      when 'chat' then '/chat'
      when 'community' then '/community'
      else '/'
    end;

    return base_url || target_path || case when rest_query <> '' then '?' || rest_query else '' end;
  end if;

  if raw_path not like '/%' then
    raw_path := '/' || raw_path;
  end if;

  return base_url || raw_path;
end;
$$;

create or replace function public.notification_owner_url(path text default '')
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  base_url constant text := 'https://motfowner.co.kr';
  raw_path text := coalesce(path, '');
begin
  if raw_path = '' or raw_path = '/' then
    return base_url;
  end if;

  if raw_path not like '/%' then
    raw_path := '/' || raw_path;
  end if;

  return base_url || raw_path;
end;
$$;

revoke all on function public.notification_user_url(text) from public;
revoke all on function public.notification_owner_url(text) from public;
grant execute on function public.notification_user_url(text) to authenticated, service_role;
grant execute on function public.notification_owner_url(text) to authenticated, service_role;
