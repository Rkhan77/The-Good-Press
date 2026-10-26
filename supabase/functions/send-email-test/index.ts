import { emailFrame, environment, json, requireServiceRequest, sendMail } from '../_shared/email.ts';

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    await requireServiceRequest(request);
    const { mailFrom, appUrl } = environment();
    const body = await request.json().catch(() => ({}));
    const recipient = typeof body.to === 'string' && body.to.includes('@') ? body.to.trim() : mailFrom;
    const notificationPreview = body.template === 'daily_notification';
    const unreadCount = Math.max(1, Math.floor(Number(body.unread_count) || 7));
    const html = emailFrame(
      notificationPreview ? `${unreadCount} stories are waiting in your test edition.` : 'Your Good Press email connection is ready.',
      notificationPreview ? 'Good things have been happening.' : 'The newsroom found the postbox.',
      notificationPreview
        ? `<p><strong>This is a private test.</strong> The newsroom gathered today’s useful progress into one calmer place.</p><p>Your sample edition has <strong>${unreadCount} unread stories</strong> waiting. No reader preferences or scheduled notifications were changed.</p>`
        : '<p>This is a private delivery test from The Good Press. Resend, Supabase and <strong>no-reply@goodpress.au</strong> are speaking to one another.</p><p>No reader notifications have been enabled.</p>',
      notificationPreview ? 'Read more' : 'Open The Good Press',
      appUrl,
      `${appUrl}/privacy.html`,
      notificationPreview ? unreadCount : undefined,
    );
    await sendMail(recipient, notificationPreview ? '[Test] Your daily dose of good things has arrived' : 'The Good Press email test', html);
    return json({ sent: true, recipient, template: notificationPreview ? 'daily_notification' : 'connection' });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Test email failed';
    return json({ error: message }, message === 'Unauthorized' ? 401 : 502);
  }
});

