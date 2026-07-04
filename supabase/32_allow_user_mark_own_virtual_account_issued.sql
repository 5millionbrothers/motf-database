-- Allow the user app to store a successful PortOne virtual-account request
-- when the server confirmation endpoint is delayed or fails.
-- The function is security definer and checks target_customer_id against
-- the payment_intents row, so users can only mark their own prepared intent.

grant execute on function public.mark_virtual_account_issued(uuid, text, jsonb) to authenticated;
