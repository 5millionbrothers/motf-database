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
