import Stripe from 'npm:stripe@^22';
import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = { 'Access-Control-Allow-Origin': 'https://goodpress.au', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '');
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

async function activePortalConfiguration() {
  const existing = await stripe.billingPortal.configurations.list({ active: true, limit: 1 });
  if (existing.data[0]) return existing.data[0];

  return await stripe.billingPortal.configurations.create({
    business_profile: { headline: 'Manage your The Good Press subscription' },
    features: {
      customer_update: { enabled: true, allowed_updates: ['email', 'name', 'address', 'phone'] },
      invoice_history: { enabled: true },
      payment_method_update: { enabled: true },
      subscription_cancel: {
        enabled: true,
        mode: 'at_period_end',
        cancellation_reason: { enabled: true, options: ['too_expensive', 'missing_features', 'switched_service', 'unused', 'other'] },
      },
      subscription_update: { enabled: false },
    },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authorization = request.headers.get('Authorization');
  const projectUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const appUrl = (Deno.env.get('APP_URL') ?? 'https://goodpress.au').replace(/\/+$/, '');
  if (!authorization || !projectUrl || !anonKey || !serviceKey || !Deno.env.get('STRIPE_SECRET_KEY')) return json({ error: 'Billing is not configured' }, 503);

  const reader = createClient(projectUrl, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user }, error: userError } = await reader.auth.getUser();
  if (userError || !user) return json({ error: 'Sign in required' }, 401);

  const admin = createClient(projectUrl, serviceKey);
  const { data: subscription } = await admin.from('subscriptions').select('provider_customer_id').eq('user_id', user.id).maybeSingle();
  if (!subscription?.provider_customer_id) return json({ error: 'No subscription was found for this account' }, 404);

  try {
    const configuration = await activePortalConfiguration();
    const session = await stripe.billingPortal.sessions.create({
      customer: subscription.provider_customer_id,
      configuration: configuration.id,
      return_url: appUrl + '/?portal=return',
    });
    return json({ url: session.url });
  } catch (error) {
    console.error('Could not create Customer Portal session', error);
    return json({ error: 'Could not open subscription settings' }, 502);
  }
});
