import { createClient } from 'npm:@supabase/supabase-js@2';

export const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});

export function baseEnvironment() {
  const projectUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const appUrl = (Deno.env.get('APP_URL') ?? 'https://goodpress.au').replace(/\/+$/, '');
  if (!projectUrl || !serviceKey) throw new Error('Supabase service is not configured');
  return { projectUrl, serviceKey, appUrl };
}

export function environment() {
  const { projectUrl, serviceKey, appUrl } = baseEnvironment();
  const tenantId = Deno.env.get('MS_TENANT_ID') ?? '';
  const clientId = Deno.env.get('MS_CLIENT_ID') ?? '';
  const clientSecret = Deno.env.get('MS_CLIENT_SECRET') ?? '';
  const mailFrom = Deno.env.get('MAIL_FROM') ?? 'readit@goodpress.au';
  if (!tenantId || !clientId || !clientSecret) throw new Error('Microsoft email service is not configured');
  return { projectUrl, serviceKey, tenantId, clientId, clientSecret, mailFrom, appUrl };
}

export function adminClient() {
  const { projectUrl, serviceKey } = baseEnvironment();
  return createClient(projectUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
}

export async function requireServiceRequest(request: Request) {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const bearer = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? '';
  const apiKey = request.headers.get('apikey') ?? '';
  if (serviceKey && (bearer === serviceKey || apiKey === serviceKey)) return;
  const candidate = apiKey || bearer;
  if (!candidate) throw new Error('Unauthorized');
  const { projectUrl } = baseEnvironment();
  const headers: Record<string, string> = { apikey: candidate };
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  const check = await fetch(`${projectUrl}/rest/v1/notification_outbox?select=id&limit=0`, { headers });
  if (!check.ok) throw new Error('Unauthorized');
}

async function graphToken() {
  const { tenantId, clientId, clientSecret } = environment();
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    scope: 'https://graph.microsoft.com/.default',
    grant_type: 'client_credentials',
  });
  const response = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenantId)}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!response.ok) throw new Error(`Microsoft token request failed (${response.status})`);
  const data = await response.json();
  if (!data.access_token) throw new Error('Microsoft token response did not include an access token');
  return String(data.access_token);
}

export async function sendMail(to: string, subject: string, html: string) {
  const { mailFrom } = environment();
  const token = await graphToken();
  const response = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(mailFrom)}/sendMail`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: {
        subject,
        body: { contentType: 'HTML', content: html },
        toRecipients: [{ emailAddress: { address: to } }],
      },
      saveToSentItems: true,
    }),
  });
  if (response.status !== 202) throw new Error(`Microsoft sendMail failed (${response.status}): ${(await response.text()).slice(0, 300)}`);
}

export const escapeHtml = (value: unknown) => String(value ?? '')
  .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;');

export function emailFrame(preheader: string, heading: string, copy: string, buttonLabel: string, buttonUrl: string, unsubscribeUrl: string) {
  return `<!doctype html><html><body style="margin:0;background:#ded8c9;color:#1d1d1b;font-family:Arial,sans-serif"><div style="display:none;max-height:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#ded8c9;padding:24px"><tr><td align="center"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:620px;background:#f4eddd;border:1px solid #1d1d1b"><tr><td style="padding:30px"><div style="font:700 11px Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;border-bottom:3px double #1d1d1b;padding-bottom:14px">The Good Press</div><h1 style="font:900 38px/1 Georgia,serif;letter-spacing:-1px;margin:24px 0 16px">${escapeHtml(heading)}</h1><div style="font:17px/1.55 Georgia,serif">${copy}</div><p style="margin:26px 0"><a href="${escapeHtml(buttonUrl)}" style="display:inline-block;background:#1d1d1b;color:#f4eddd;padding:14px 18px;text-decoration:none;font-weight:800">${escapeHtml(buttonLabel)}</a></p><div style="border-top:1px solid #b7b0a1;padding-top:16px;color:#716c63;font-size:11px;line-height:1.5">Sent by The Good Press · <a href="mailto:readit@goodpress.au" style="color:#716c63">readit@goodpress.au</a><br><a href="${escapeHtml(unsubscribeUrl)}" style="color:#716c63">Unsubscribe from Good Press emails</a></div></td></tr></table></td></tr></table></body></html>`;
}

