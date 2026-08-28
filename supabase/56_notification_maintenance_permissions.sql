do $$
begin
  if to_regprocedure('public.sync_partner_settlements()') is not null then
    grant execute on function public.sync_partner_settlements() to authenticated, service_role;
  end if;
end;
$$;
