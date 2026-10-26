import { adminClient, baseEnvironment, escapeHtml } from '../_shared/email.ts';

const page = (heading: string, copy: string, status = 200) => new Response(`<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(heading)} · The Good Press</title><body style="margin:0;background:#ded8c9;color:#1d1d1b;font-family:Arial,sans-serif;display:grid;min-height:100vh;place-items:center"><main style="width:min(82vw,520px);background:#f4eddd;border:1px solid #1d1d1b;padding:32px"><div style="font-size:11px;font-weight:800;letter-spacing:2px;text-transform:uppercase;border-bottom:3px double #1d1d1b;padding-bottom:14px">The Good Press</div><h1 style="font:900 40px/1 Georgia,serif">${escapeHtml(heading)}</h1><p style="font:17px/1.5 Georgia,serif">${escapeHtml(copy)}</p><a href="${escapeHtml(baseEnvironment().appUrl)}" style="color:#1d1d1b;font-weight:800">Return to The Good Press</a></main></body></html>`, { status, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });

Deno.serve(async (request) => {
  if (request.method !== 'GET') return page('That link cannot be used.', 'Open the unsubscribe link from your Good Press email.', 405);
  const token = new URL(request.url).searchParams.get('token');
  if (!token) return page('That link is incomplete.', 'Open the full unsubscribe link from your Good Press email.', 400);
  try {
    const { data, error } = await adminClient().from('notification_preferences').update({ new_articles: false, card_reset: false, unsubscribed_at: new Date().toISOString() }).eq('unsubscribe_token', token).select('user_id').maybeSingle();
    if (error) throw error;
    if (!data) return page('That link has expired.', 'No notification preferences were changed.', 404);
    return page('You’re unsubscribed.', 'The newsroom will keep the email bell quiet. You can opt in again from Settings at any time.');
  } catch {
    return page('We could not update that preference.', 'Please try again or email support@goodpress.au.', 500);
  }
});

