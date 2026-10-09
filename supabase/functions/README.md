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
