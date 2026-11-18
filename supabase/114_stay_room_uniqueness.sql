begin;

create or replace function public.stay_room_name_key(room_name text)
returns text language sql immutable strict set search_path='' as $$
  select lower(btrim(regexp_replace(normalize(room_name, NFKC),'^[[:space:]]+|[[:space:]]+$','','g')));
$$;

alter table public.offerings add column if not exists stay_room_key text;

create or replace function public.set_stay_room_key()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.stay_room_key:=case when new.retired_at is null and exists (
    select 1 from public.businesses b where b.id=new.business_id and b.business_type='stay'
  ) then nullif(public.stay_room_name_key(new.name),'') end;
  return new;
end;
$$;
revoke all on function public.set_stay_room_key() from public,anon,authenticated;
drop trigger if exists set_stay_room_key on public.offerings;
create trigger set_stay_room_key
before insert or update of business_id,name,retired_at,stay_room_key on public.offerings
for each row execute function public.set_stay_room_key();

-- On ambiguous existing rooms, stop rather than choose which ID a reservation should use.
do $$
declare conflict record;
begin
  select b.business_name,public.stay_room_name_key(o.name) as room_key into conflict
  from public.offerings o join public.businesses b on b.id=o.business_id
  where b.business_type='stay' and o.retired_at is null
  group by b.id,b.business_name,public.stay_room_name_key(o.name)
  having count(*)>1 and public.stay_room_name_key(o.name)<>''
  order by b.business_name,room_key limit 1;
  if found then
    raise exception '객실 중복 사전 확인 필요: % / %. 112번 정리 적용 여부와 중복 객실을 확인해주세요.',
      conflict.business_name,conflict.room_key;
  end if;
end;
$$;
update public.offerings o set stay_room_key=public.stay_room_name_key(o.name)
from public.businesses b where b.id=o.business_id and b.business_type='stay' and o.retired_at is null
  and o.stay_room_key is distinct from nullif(public.stay_room_name_key(o.name),'');

-- Deferred so a single snapshot may swap two room names or retire an omitted room.
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.offerings'::regclass and conname='unique_current_stay_room') then
    alter table public.offerings add constraint unique_current_stay_room
    unique (business_id,stay_room_key) deferrable initially deferred;
  end if;
end $$;

create or replace function public.refresh_stay_room_keys_on_type_change()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.offerings set stay_room_key=null where business_id=new.id and retired_at is null;
  return new;
end;
$$;
revoke all on function public.refresh_stay_room_keys_on_type_change() from public,anon,authenticated;
drop trigger if exists refresh_stay_room_keys_on_type_change on public.businesses;
create trigger refresh_stay_room_keys_on_type_change after update of business_type on public.businesses
for each row when (old.business_type is distinct from new.business_type)
execute function public.refresh_stay_room_keys_on_type_change();

create or replace function public.resolve_stay_offering_snapshot(target_business_id uuid,items jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; room public.offerings%rowtype; item_id uuid; matched_id uuid; matches integer;
  names text[]:='{}'; ids uuid[]:='{}'; room_name text; result jsonb:='[]'; is_stay boolean;
begin
  select business_type='stay' into is_stay from public.businesses where id=target_business_id for update;
  if not found then raise exception '업장을 찾을 수 없습니다.'; end if;
  if not is_stay then return items; end if;
  if items is null or jsonb_typeof(items)<>'array' then raise exception '객실 목록을 확인해주세요.'; end if;
  for item in select value from jsonb_array_elements(items) loop
    room_name:=public.stay_room_name_key(item->>'name');
    if coalesce(room_name,'')='' then raise exception '객실 이름을 입력해주세요.'; end if;
    if room_name=any(names) then raise exception '신청서에 같은 이름의 객실이 두 번 있습니다: %. 최신 목록에서 중복을 확인한 뒤 다시 신청해주세요.',item->>'name'; end if;
    names:=array_append(names,room_name);
    item_id:=nullif(item->>'id','')::uuid;
    select * into room from public.offerings where id=item_id;
    if found and room.business_id<>target_business_id then raise exception '다른 업장의 객실은 수정할 수 없습니다.'; end if;
    if room.id is null or room.retired_at is not null then
      select count(*),min(o.id::text)::uuid into matches,matched_id from public.offerings o
      where o.business_id=target_business_id and o.retired_at is null and o.stay_room_key=room_name;
      if matches>1 then raise exception '현재 저장된 객실에 같은 이름이 여러 개 있습니다: %',item->>'name'; end if;
      if matched_id is not null then item_id:=matched_id;
      elsif room.retired_at is not null then raise exception '삭제된 객실의 이전 신청입니다. 최신 객실 목록으로 다시 신청해주세요: %',item->>'name';
      else item_id:=coalesce(item_id,gen_random_uuid()); end if;
    end if;
    if item_id=any(ids) then raise exception '한 객실이 신청서에 두 번 연결되어 있습니다: %',item->>'name'; end if;
    ids:=array_append(ids,item_id);
    result:=result||jsonb_build_array(jsonb_set(item,'{id}',to_jsonb(item_id::text)));
  end loop;
  return result;
end;
$$;
revoke all on function public.resolve_stay_offering_snapshot(uuid,jsonb) from public,anon,authenticated;

create or replace function public.validate_pending_listing_rooms()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='pending' then
    new.proposed_offerings:=public.resolve_stay_offering_snapshot(new.business_id,new.proposed_offerings);
  end if;
  return new;
end;
$$;
revoke all on function public.validate_pending_listing_rooms() from public,anon,authenticated;
drop trigger if exists validate_pending_listing_rooms on public.business_listing_review_requests;
create trigger validate_pending_listing_rooms before insert or update of proposed_offerings,business_id
on public.business_listing_review_requests for each row execute function public.validate_pending_listing_rooms();

notify pgrst,'reload schema';
commit;
