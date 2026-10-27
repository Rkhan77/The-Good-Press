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
  const resendApiKey = Deno.env.get('RESEND_API_KEY') ?? '';
  const mailFrom = Deno.env.get('MAIL_FROM') ?? 'no-reply@goodpress.au';
  const mailFromName = Deno.env.get('MAIL_FROM_NAME') ?? 'The Good Press';
  const mailReplyTo = Deno.env.get('MAIL_REPLY_TO') ?? 'support@goodpress.au';
  if (!resendApiKey) throw new Error('Resend email service is not configured');
  return { projectUrl, serviceKey, resendApiKey, mailFrom, mailFromName, mailReplyTo, appUrl };
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

type SendMailOptions = {
  fromEmail?: string;
  fromName?: string;
  replyTo?: string;
};

export async function sendMail(to: string, subject: string, html: string, options: SendMailOptions = {}) {
  const { resendApiKey, mailFrom, mailFromName, mailReplyTo } = environment();
  const fromEmail = options.fromEmail ?? mailFrom;
  const fromName = options.fromName ?? mailFromName;
  const replyTo = options.replyTo ?? mailReplyTo;
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: `${fromName} <${fromEmail}>`,
      to: [to],
      reply_to: replyTo,
      subject,
      html,
    }),
  });
  const responseBody = await response.text();
  if (!response.ok) throw new Error(`Resend send failed (${response.status}): ${responseBody.slice(0, 300)}`);
  const result = responseBody ? JSON.parse(responseBody) : {};
  if (!result.id) throw new Error('Resend accepted the request without returning an email ID');
  return String(result.id);
}

export const escapeHtml = (value: unknown) => String(value ?? '')
  .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;');

export function emailFrame(preheader: string, heading: string, copy: string, buttonLabel: string, buttonUrl: string, unsubscribeUrl: string, unreadCount?: number, senderAddress = 'no-reply@goodpress.au') {
  const count = Number.isFinite(unreadCount) ? Math.max(0, Math.floor(Number(unreadCount))) : null;
  const unreadBadge = count === null ? '' : `<span style="color:#e74a32;font:800 11px Arial,sans-serif;letter-spacing:1.4px;text-transform:uppercase;white-space:nowrap">${count} unread</span>`;
  return `<!doctype html><html><body style="margin:0;background:#ded8c9;color:#1d1d1b;font-family:Arial,sans-serif"><div style="display:none;max-height:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#ded8c9;padding:24px"><tr><td align="center"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:620px;background:#f4eddd;border:1px solid #1d1d1b"><tr><td style="padding:30px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-bottom:3px double #1d1d1b"><tr><td style="padding-bottom:14px;font:700 11px Arial,sans-serif;letter-spacing:2px;text-transform:uppercase">The Good Press</td><td align="right" style="padding-bottom:14px">${unreadBadge}</td></tr></table><h1 style="font:900 38px/1 Georgia,serif;letter-spacing:-1px;margin:24px 0 16px">${escapeHtml(heading)}</h1><div style="font:17px/1.55 Georgia,serif">${copy}</div><p style="margin:26px 0"><a href="${escapeHtml(buttonUrl)}" style="display:inline-block;background:#1d1d1b;color:#f4eddd;padding:14px 18px;text-decoration:none;font-weight:800">${escapeHtml(buttonLabel)}</a></p><div style="border-top:1px solid #b7b0a1;padding-top:16px;color:#716c63;font-size:11px;line-height:1.5">Sent automatically by The Good Press from ${escapeHtml(senderAddress)}.<br>Need help? <a href="mailto:support@goodpress.au" style="color:#716c63">support@goodpress.au</a> · <a href="${escapeHtml(unsubscribeUrl)}" style="color:#716c63">Unsubscribe</a></div></td></tr></table></td></tr></table></body></html>`;
}

export function authEmailFrame(preheader: string, heading: string, copy: string, buttonLabel: string, buttonUrl: string) {
  return `<!doctype html><html><body style="margin:0;background:#ded8c9;color:#1d1d1b;font-family:Arial,sans-serif"><div style="display:none;max-height:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#ded8c9;padding:24px"><tr><td align="center"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:620px;background:#f4eddd;border:1px solid #1d1d1b"><tr><td style="padding:30px"><div style="font:700 11px Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;border-bottom:3px double #1d1d1b;padding-bottom:14px">The Good Press</div><h1 style="font:900 38px/1 Georgia,serif;letter-spacing:-1px;margin:24px 0 16px">${escapeHtml(heading)}</h1><div style="font:17px/1.55 Georgia,serif">${copy}</div><p style="margin:26px 0"><a href="${escapeHtml(buttonUrl)}" style="display:inline-block;background:#1d1d1b;color:#f4eddd;padding:14px 18px;text-decoration:none;font-weight:800">${escapeHtml(buttonLabel)}</a></p><div style="margin-top:28px;border-top:1px solid #b7b0a1;padding-top:16px;color:#716c63;font-size:11px;line-height:1.5">This is an automated security email from no-reply@goodpress.au. If you did not request it, you can safely ignore it.<br>Need help? <a href="mailto:support@goodpress.au" style="color:#716c63">support@goodpress.au</a></div></td></tr></table></td></tr></table></body></html>`;
}

