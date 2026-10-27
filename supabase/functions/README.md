# Stripe subscription setup

The Good Press has an A$3.99/month Unlimited plan. The browser never receives a Stripe secret.

## 1. Create the Stripe product

Create an **Unlimited cards** product in Stripe with a recurring monthly price of **AUD 3.99**. Copy its price ID (starts with `price_`).

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

The notification system sends through Resend using `no-reply@goodpress.au`, with replies directed to `support@goodpress.au`. Readers start opted out and choose the notifications relevant to their edition in Settings.

Every verified new account receives one service welcome email from `welcome@goodpress.au`. Email/password readers receive it only after confirming their email address; Google readers are already verified at account creation and receive only the welcome. Returning users do not receive it again. This is independent of optional digest and unread-reminder preferences and is protected by a per-user idempotency key.

## Authentication emails through Resend

`send_auth_email_hook` is the Supabase Postgres Send Email Auth Hook. It places confirmation, password recovery, invitation, magic-link, reauthentication, and email-change messages into the protected delivery queue. The worker sends them through the Resend Email API from `no-reply@goodpress.au` within one minute.

## 1. Deploy the schema

Deploy the email migrations through `20261026000000_segmented_notification_schedule.sql`. They add reader preferences, a protected delivery queue, delivery records, unsubscribe tokens, the 24-hour card-refresh queue hook, the subscriber daily digest, and twice-weekly unread reminders.

## 2. Configure Resend

Add and verify `goodpress.au` in Resend first. Add every DNS record Resend provides, wait for the domain status to become **Verified**, then create a sending API key. Store these Edge Function secrets in Supabase:

- `RESEND_API_KEY`
- `MAIL_FROM=no-reply@goodpress.au`
- `MAIL_FROM_NAME=The Good Press`
- `MAIL_REPLY_TO=support@goodpress.au`
- `APP_URL=https://goodpress.au`

Leave `NOTIFICATIONS_LIVE` unset or set to `false` during initial testing. Never put the Resend API key in the website. The Microsoft 365 mailbox can remain active for receiving replies; Resend handles outbound delivery.

## 3. Deploy and test the functions

Deploy `send-email-test`, `queue-notifications`, `notification-worker`, and `unsubscribe`. Invoke `send-email-test` from a trusted server request with the Supabase service-role key in the `Authorization: Bearer ...` header. Its optional JSON body is:

```json
{ "to": "contact@goodpress.au" }
```

The test sends one private message and does not contact readers. Confirm that the message arrives from The Good Press before enabling delivery.

## 4. Notification schedule

`20261026000000_segmented_notification_schedule.sql` replaces immediate article alerts with three plan-aware schedules:

- Unlimited subscribers can opt into one digest at 12:00 PM Australia/Perth time. It reports how many new and unread stories are available and lists the new article titles in numbered order.
- Free signed-in readers can opt into one digest when their 25-card allowance resets. It includes the number of unread stories then available.
- Either plan can opt into unread reminders at 12:00 PM each Tuesday and Friday. No reminder is queued when the reader has nothing unread.

The worker randomly rotates three daily-edition messages and three unread-reminder messages. Emails do not list categories or story titles. Every notification shows the unread count in the newspaper masthead and uses a `Read more` call to action.

## 5. Schedule the worker and go live

`20261025000000_automate_email_notifications.sql` schedules `notification-worker` every five minutes using a private key generated inside Supabase Vault. `20261026000000_segmented_notification_schedule.sql` adds the noon queues. Once the private test succeeds, set `NOTIFICATIONS_LIVE=true`. The worker rechecks consent and plan eligibility before every send, provides a one-click unsubscribe link, retries temporary failures, and records the outcome.
