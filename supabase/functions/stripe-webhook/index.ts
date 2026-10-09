import Stripe from 'npm:stripe@17';
import { createClient } from 'npm:@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '');
const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const signature = request.headers.get('stripe-signature');
  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!signature || !secret) return new Response('Missing Stripe signature', { status: 400 });

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(await request.text(), signature, secret, undefined, cryptoProvider);
  } catch (error) {
    console.error('Stripe signature verification failed', error);
    return new Response('Invalid signature', { status: 400 });
  }

  if (!['customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted'].includes(event.type)) return Response.json({ received: true });
  const subscription = event.data.object as Stripe.Subscription;
  const projectUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const admin = createClient(projectUrl, serviceKey);
  const customerId = typeof subscription.customer === 'string' ? subscription.customer : subscription.customer.id;
  let userId = subscription.metadata.supabase_user_id;
  if (!userId) {
    const { data } = await admin.from('subscriptions').select('user_id').eq('provider_customer_id', customerId).maybeSingle();
    userId = data?.user_id ?? '';
  }
  if (!userId) return new Response('Subscription has no reader', { status: 400 });

  await admin.from('subscriptions').upsert({
    user_id: userId,
    provider: 'stripe',
    provider_customer_id: customerId,
    provider_subscription_id: subscription.id,
    status: subscription.status,
    current_period_end: subscription.current_period_end ? new Date(subscription.current_period_end * 1000).toISOString() : null,
    cancel_at_period_end: subscription.cancel_at_period_end,
  }, { onConflict: 'user_id' });
  return Response.json({ received: true });
});
