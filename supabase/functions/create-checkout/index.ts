import Stripe from 'npm:stripe@^22';
import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = { 'Access-Control-Allow-Origin': 'https://goodpress.au', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '');
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authorization = request.headers.get('Authorization');
  if (!authorization) return json({ error: 'Sign in required' }, 401);

  const projectUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const priceId = Deno.env.get('STRIPE_PRICE_ID') ?? '';
  const appUrl = (Deno.env.get('APP_URL') ?? 'https://goodpress.au').replace(/\/+$/, '');
  if (!projectUrl || !anonKey || !serviceKey || !priceId || !Deno.env.get('STRIPE_SECRET_KEY')) return json({ error: 'Billing is not configured' }, 503);

  const reader = createClient(projectUrl, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user }, error: userError } = await reader.auth.getUser();
  if (userError || !user) return json({ error: 'Sign in required' }, 401);

  const admin = createClient(projectUrl, serviceKey);
  const { data: existing } = await admin.from('subscriptions').select('provider_customer_id,status').eq('user_id', user.id).maybeSingle();
  const customerId = existing?.provider_customer_id || (await stripe.customers.create({ email: user.email ?? undefined, metadata: { supabase_user_id: user.id } })).id;
  const session = await stripe.checkout.sessions.create({
    mode: 'subscription',
    customer: customerId,
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: appUrl + '/?checkout=success',
    cancel_url: appUrl + '/?checkout=cancelled',
    client_reference_id: user.id,
    metadata: { supabase_user_id: user.id },
    subscription_data: { metadata: { supabase_user_id: user.id } },
  });
  await admin.from('subscriptions').upsert({ user_id: user.id, provider: 'stripe', provider_customer_id: customerId, status: existing?.status ?? 'pending' }, { onConflict: 'user_id' });
  return json({ url: session.url });
});
