import { emailFrame, environment, json, requireServiceRequest, sendMail } from '../_shared/email.ts';

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    await requireServiceRequest(request);
    const { mailFrom, appUrl } = environment();
    const body = await request.json().catch(() => ({}));
    const recipient = typeof body.to === 'string' && body.to.includes('@') ? body.to.trim() : mailFrom;
    const html = emailFrame(
      'Your Good Press email connection is ready.',
      'The newsroom found the postbox.',
      '<p>This is a private delivery test from The Good Press. Resend, Supabase and <strong>readit@goodpress.au</strong> are speaking to one another.</p><p>No reader notifications have been enabled.</p>',
      'Open The Good Press',
      appUrl,
      `${appUrl}/privacy.html`,
    );
    await sendMail(recipient, 'The Good Press email test', html);
    return json({ sent: true, recipient });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Test email failed';
    return json({ error: message }, message === 'Unauthorized' ? 401 : 502);
  }
});

