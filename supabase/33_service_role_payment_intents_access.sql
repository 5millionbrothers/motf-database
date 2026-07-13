-- Allow Vercel server functions that use SUPABASE_SERVICE_ROLE_KEY
-- to read prepared payment intents before calling the secure RPC functions.
-- RLS bypass does not replace table privileges, so service_role still needs
-- explicit grants for direct PostgREST reads.

grant usage on schema public to service_role;
grant select on public.payment_intents to service_role;

-- Keep RPC execution grants explicit for the PortOne virtual-account flow.
grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to service_role;
grant execute on function public.finalize_payment_intent(uuid, text, text, jsonb) to service_role;
