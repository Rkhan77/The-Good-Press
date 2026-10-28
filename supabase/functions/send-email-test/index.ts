import { emailFrame, environment, json, requireServiceRequest, sendMail } from '../_shared/email.ts';

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    await requireServiceRequest(request);
    const { mailFrom, appUrl } = environment();
    const body = await request.json().catch(() => ({}));
    const recipient = typeof body.to === 'string' && body.to.includes('@') ? body.to.trim() : mailFrom;
    const notificationPreview = body.template === 'daily_notification';
    const unreadDigestPreview = body.template === 'unread_digest';
    const unreadCount = Math.max(1, Math.floor(Number(body.unread_count) || 7));
    const sampleTitles = [
      'A community project opens new doors',
      'A practical solution finds its footing',
      'Local volunteers turn a small idea into progress',
      'A new investment backs useful work',
      'An education initiative reaches its next milestone',
    ];
    const subscriberDigestArticles = [
      { title: 'A community project opens new doors', brief: 'A neighbourhood-led project has opened with new shared facilities, practical services and room for local groups to grow their work.' },
      { title: 'A practical solution finds its footing', brief: 'A tested local solution is moving into wider use after early results showed it could save time and improve access for residents.' },
      { title: 'Local volunteers turn a small idea into progress', brief: 'Volunteers have expanded a small community effort into a regular program that now reaches more families each week.' },
      { title: 'A new investment backs useful work', brief: 'Fresh funding will support equipment, training and the next stage of a project designed to deliver a measurable public benefit.' },
      { title: 'An education initiative reaches its next milestone', brief: 'The initiative has completed its latest stage, giving students and educators access to additional learning resources.' },
    ];
    const subscriberDigestList = `<p style="margin-bottom:8px"><strong>Recently added:</strong></p><ol style="margin:0 0 20px;padding-left:24px">${subscriberDigestArticles.map(article => `<li style="margin:0 0 14px"><strong>${article.title}</strong><p style="margin:5px 0 0;color:#4f4b45">${article.brief}</p></li>`).join('')}</ol>`;
    const unreadDigestCopy = `<p>Doomscrolling called. We sent it to voicemail.</p><p>You have <strong>${unreadCount} unread stories</strong> waiting in The Good Press.</p><p style="margin-bottom:8px"><strong>Recently added:</strong></p><ol style="margin:0 0 20px;padding-left:24px">${sampleTitles.map(title => `<li style="margin:0 0 8px">${title}</li>`).join('')}</ol>`;
    const unreadDigestSubscribe = `<div style="margin:0 0 24px;padding:18px;border:1px solid #b7b0a1"><p style="margin:0 0 12px"><strong>Want more of this?</strong><br>Subscribe for unlimited stories and a fresh inspiring digest every day.</p><a href="${appUrl}/?subscribe=1" style="display:inline-block;background:#e74a32;color:#fff;padding:11px 15px;text-decoration:none;font:800 13px Arial,sans-serif">Subscribe</a></div>`;
    const html = emailFrame(
      unreadDigestPreview ? `${unreadCount} stories are waiting for a calmer scroll.` : notificationPreview ? `${unreadCount} stories are waiting in your test edition.` : 'Your Good Press email connection is ready.',
      unreadDigestPreview ? 'Your attention span is not a lost cause.' : notificationPreview ? 'Good things have been happening.' : 'The newsroom found the postbox.',
      unreadDigestPreview
        ? unreadDigestCopy
        : notificationPreview
        ? `<p><strong>This is a private test.</strong> The newsroom gathered today’s useful progress into one calmer place.</p><p>Your sample edition has <strong>${unreadCount} unread stories</strong> waiting. No reader preferences or scheduled notifications were changed.</p>${subscriberDigestList}`
        : '<p>This is a private delivery test from The Good Press. Resend, Supabase and <strong>no-reply@goodpress.au</strong> are speaking to one another.</p><p>No reader notifications have been enabled.</p>',
      notificationPreview || unreadDigestPreview ? 'Login' : 'Open The Good Press',
      appUrl,
      `${appUrl}/privacy.html`,
      notificationPreview || unreadDigestPreview ? unreadCount : undefined,
      'no-reply@goodpress.au',
      unreadDigestPreview ? unreadDigestSubscribe : '',
      !unreadDigestPreview,
    );
    const previewTime = new Intl.DateTimeFormat('en-AU', {
      timeZone: 'Australia/Perth',
      day: '2-digit',
      month: 'short',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    }).format(new Date());
    const subject = unreadDigestPreview ? `[Test] Your attention deserves better news · ${previewTime}` : notificationPreview ? `[Test] Your daily dose of good things has arrived · ${previewTime}` : `The Good Press email test · ${previewTime}`;
    await sendMail(recipient, subject, html);
    return json({ sent: true, recipient, template: unreadDigestPreview ? 'unread_digest' : notificationPreview ? 'daily_notification' : 'connection' });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Test email failed';
    return json({ error: message }, message === 'Unauthorized' ? 401 : 502);
  }
});

