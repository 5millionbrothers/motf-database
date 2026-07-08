-- Allow approved partners to see virtual-account payment intents for their own business.
-- Without this policy, only the customer and admin can read payment_intents, so owners
-- cannot see "deposit pending" reservations/orders before the PortOne webhook finalizes them.

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'payment_intents'
      and policyname = 'payment_intents_read_partner_business'
  ) then
    create policy "payment_intents_read_partner_business"
    on public.payment_intents
    for select
    to authenticated
    using (
      exists (
        select 1
        from public.businesses b
        where b.id = (payment_intents.draft ->> 'business_id')::uuid
          and b.owner_id = auth.uid()
          and b.approval_status = 'approved'
      )
    );
  end if;
end
$$;
