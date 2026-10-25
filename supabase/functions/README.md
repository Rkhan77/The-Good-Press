# Stripe subscription setup

The Good Press has a $5/month Unlimited plan. The browser never receives a Stripe secret.

## 1. Create the Stripe product

Create an **Unlimited cards** product in Stripe with a recurring monthly price of **AUD 5.00**. Copy its price ID (starts with `price_`).

## 2. Deploy the database migration

Deploy `supabase/migrations/20261009000000_add_subscriptions.sql` through the existing Supabase GitHub integration or SQL migration workflow.

## 3. Deploy functions and secrets

Deploy the `create-checkout` and `stripe-webhook` Edge Functions. In Supabase → Edge Functions → Secrets, set:

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_ID`
- `APP_URL=https://goodpress.au`

Supabase-provided `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are used by the functions; never put the service role or Stripe secret in the website.

## 4. Add the Stripe webhook

In Stripe, create a webhook endpoint:

`https://ltdzjanqhxrleqbtkpoo.supabase.co/functions/v1/stripe-webhook`

Subscribe it to:

- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`

Copy the webhook signing secret into `STRIPE_WEBHOOK_SECRET`. Use Stripe test mode first, then repeat with live keys when the complete payment flow is confirmed.

# Consent-based email notifications

The notification system sends from the licensed Microsoft 365 mailbox `readit@goodpress.au`. Readers start opted out and must enable either notification in Settings.

Every newly created account receives one immediate service welcome email. This is independent of the optional new-article and card-refresh preferences and is protected by a per-user idempotency key, so retries cannot send a second welcome message.

## Authentication emails through Microsoft 365

`send_auth_email_hook` is the Supabase Postgres Send Email Auth Hook. It places confirmation, password recovery, invitation, magic-link, reauthentication, and email-change messages into the protected delivery queue. The worker sends them through Microsoft Graph from `readit@goodpress.au` within one minute. This avoids Exchange Online's retired password-based SMTP authentication and does not require another shared secret.

## 1. Deploy the schema

Deploy `supabase/migrations/20261024000000_email_notifications.sql`. It adds reader preferences, a protected delivery queue, delivery records, unsubscribe tokens, and the 24-hour card-refresh queue hook.

## 2. Configure Microsoft Graph

The Entra application needs the Microsoft Graph **Application** permission `Mail.Send` with tenant admin consent. Store these Edge Function secrets in Supabase:

- `MS_TENANT_ID`
- `MS_CLIENT_ID`
- `MS_CLIENT_SECRET`
- `MAIL_FROM=readit@goodpress.au`
- `APP_URL=https://goodpress.au`

Leave `NOTIFICATIONS_LIVE` unset or set to `false` during testing. Never put any of these values in the website.

## 3. Deploy and test the functions

Deploy `send-email-test`, `queue-notifications`, `notification-worker`, and `unsubscribe`. Invoke `send-email-test` from a trusted server request with the Supabase service-role key in the `Authorization: Bearer ...` header. Its optional JSON body is:

```json
{ "to": "readit@goodpress.au" }
```

The test sends one private message and does not contact readers. Confirm that the message arrives from The Good Press before enabling delivery.

## 4. Connect the article workflow

New articles are now connected automatically. When n8n inserts an article with `status = 'published'`, Supabase adds it to a ten-minute digest for every reader who opted into new-article emails. Articles inserted together are combined into one email, so n8n does not need another HTTP node.

For a manual or recovery batch, make one POST request to:

`https://ltdzjanqhxrleqbtkpoo.supabase.co/functions/v1/queue-notifications`

Use the service-role key as both a Bearer token and `apikey`, and send only the inserted article IDs:

```json
{ "article_ids": [351, 352, 353] }
```

The queue is idempotent: submitting the same batch twice does not produce duplicate reader emails.

## 5. Schedule the worker and go live

`20261025000000_automate_email_notifications.sql` schedules `notification-worker` every five minutes using a private key generated inside Supabase Vault. Once the private test succeeds, set `NOTIFICATIONS_LIVE=true`. The worker rechecks consent before every send, provides a one-click unsubscribe link, retries temporary failures, and records the outcome.
