begin;

-- Preserve the policy version of existing payment intents, including unfinished checkouts.
create or replace function public.snapshot_stay_refund_policy()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.kind='stay' then
    if tg_op='INSERT' then
      new.draft:=jsonb_set(new.draft,'{stay_refund_policy_version}','"30_15_v1"'::jsonb);
    elsif old.draft ? 'stay_refund_policy_version' then
      new.draft:=jsonb_set(new.draft,'{stay_refund_policy_version}',old.draft->'stay_refund_policy_version');
    else
      new.draft:=new.draft-'stay_refund_policy_version';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists snapshot_stay_refund_policy on public.payment_intents;
create trigger snapshot_stay_refund_policy before insert or update of draft on public.payment_intents
for each row execute function public.snapshot_stay_refund_policy();

commit;
