# PortOne KG Inicis virtual-account rollout

## Flow

1. User submits a stay reservation or market order form.
2. Supabase creates a `payment_intents` row with the DB-calculated amount.
3. The browser opens PortOne V2 with `payMethod = VIRTUAL_ACCOUNT`.
4. When a virtual account is issued, `/api/confirm-payment` verifies the payment with PortOne and stores `payment_intents.status = virtual_account_issued`.
5. No reservation or market order is created yet.
6. When the user deposits money, PortOne sends a webhook to `/api/portone-webhook`.
7. The webhook verifies the payment with PortOne again.
8. If PortOne status is `PAID`, `finalize_payment_intent` creates exactly one reservation or market order.

## Vercel environment variables

```text
PORTONE_STORE_ID=
PORTONE_CHANNEL_KEY=
PORTONE_API_SECRET=
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SERVICE_ROLE_KEY=
NAVER_MAP_KEY_ID=
```

`PORTONE_API_SECRET` and `SUPABASE_SERVICE_ROLE_KEY` must stay server-only.

## PortOne console

- PG/channel: KG Inicis
- Payment method used by the app: `VIRTUAL_ACCOUNT`
- Webhook URL: `https://motf.co.kr/api/portone-webhook`

## Test points

- Virtual account issuance changes `payment_intents.status` to `virtual_account_issued`.
- User mypage shows issued virtual-account payments as `입금 대기`.
- Depositing to the virtual account changes the intent to `confirmed`.
- Only after deposit does the reservation/order appear for the user and owner/admin.
- Re-running the webhook does not create duplicate reservations/orders.

## Stay base charge and post-booking extra charge

1. The first stay payment contains only the room base price for the selected dates.
2. Guest overage and facilities such as barbecue, karaoke, pool, pickup, and equipment are not charged at booking time.
3. After confirmation, an owner submits an itemized extra-charge request.
4. An admin approves or rejects it. An admin-created request is approved immediately.
5. The user pays the approved request through a separate KG Inicis virtual account.
6. A paid extra charge is included in the final reservation total and partner settlement as a separate transaction.

The first stay order uses `kind = stay`; the separate request uses `kind = extra_charge` and an `ME-...` order ID. They must remain separate because they have different issue dates, expiration times, and settlement records.

## Virtual-account refunds

- A reservation rejection requests a full refund automatically.
- A user cancellation applies the service policy to the base accommodation payment: 14 days or more 100%, 7 to 13 days 50%, 3 to 6 days 20%, and less than 3 days 0%.
- Partial refunds are sent through PortOne with `amount` and `currentCancellableAmount`.
- KG Inicis virtual-account refunds require bank, account number, and account holder name. They are stored separately in `customer_refund_accounts` and are readable only by the signed-in user and the server service role.
- Confirm that the live KG Inicis contract includes virtual-account refund support before launch. Without it, the refund is recorded as failed for manual operator handling.
- Old reservations created before refund-account collection may also require manual handling.
