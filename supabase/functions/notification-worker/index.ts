import { adminClient, emailFrame, environment, escapeHtml, json, requireServiceRequest, sendMail } from '../_shared/email.ts';

type Job = { id: number; kind: 'welcome' | 'new_articles' | 'card_reset'; user_id: string; payload: { article_ids?: number[] }; attempts: number };

async function complete(admin: ReturnType<typeof adminClient>, job: Job, status: 'sent' | 'failed' | 'skipped', email: string, detail?: string) {
  const now = new Date().toISOString();
  await admin.from('notification_outbox').update({ status, sent_at: status === 'sent' ? now : null, last_error: detail ?? null }).eq('id', job.id);
  await admin.from('notification_deliveries').upsert({ outbox_id: job.id, user_id: job.user_id, kind: job.kind, recipient_email: email || 'unavailable', status, detail: detail ?? null }, { onConflict: 'outbox_id' });
}

async function retry(admin: ReturnType<typeof adminClient>, job: Job, message: string) {
  const failed = job.attempts >= 5;
  const delayMinutes = Math.min(60, 2 ** Math.max(1, job.attempts));
  await admin.from('notification_outbox').update({ status: failed ? 'failed' : 'pending', scheduled_for: new Date(Date.now() + delayMinutes * 60000).toISOString(), last_error: message.slice(0, 500) }).eq('id', job.id);
}

async function requireWorkerRequest(request: Request) {
  const cronSecret = request.headers.get('X-Worker-Secret') ?? '';
  if (cronSecret) {
    const { data, error } = await adminClient().rpc('authorize_notification_worker', { p_secret: cronSecret });
    if (!error && data === true) return;
  }
  await requireServiceRequest(request);
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    await requireWorkerRequest(request);
    if (Deno.env.get('NOTIFICATIONS_LIVE') !== 'true') return json({ enabled: false, processed: 0 });
    const admin = adminClient();
    const { appUrl, projectUrl } = environment();
    const { data, error } = await admin.rpc('claim_notification_jobs', { p_limit: 20 });
    if (error) throw error;
    let sent = 0, skipped = 0, failed = 0;

    for (const job of (data ?? []) as Job[]) {
      let recipient = '';
      try {
        const [{ data: preference }, { data: authData }] = await Promise.all([
          admin.from('notification_preferences').select('new_articles,card_reset,unsubscribed_at,unsubscribe_token').eq('user_id', job.user_id).maybeSingle(),
          admin.auth.admin.getUserById(job.user_id),
        ]);
        recipient = authData.user?.email ?? '';
        const allowed = preference && !preference.unsubscribed_at && (job.kind === 'welcome' || (job.kind === 'new_articles' ? preference.new_articles : preference.card_reset));
        if (!allowed || !recipient) { await complete(admin, job, 'skipped', recipient, 'Reader is not eligible or opted in'); skipped++; continue; }

        const unsubscribeUrl = `${projectUrl}/functions/v1/unsubscribe?token=${encodeURIComponent(preference.unsubscribe_token)}`;
        if (job.kind === 'welcome') {
          const html = emailFrame(
            'Your good-news edition is ready.',
            'Welcome to the brighter side of the news.',
            '<p>Thanks for joining The Good Press, where useful progress gets the front page and the news does not pick a fight with your mood.</p><p>Choose the locations and topics you care about, then support the stories you want to see more of. Your personal edition will learn what matters to you—quietly, helpfully, and without shouting across the newsroom.</p><p><strong>See you at the newsstand,<br>The GP Team</strong></p>',
            'Build your Good Edition',
            appUrl,
            unsubscribeUrl,
          );
          await sendMail(recipient, 'Welcome to The Good Press', html);
        } else if (job.kind === 'card_reset') {
          const since = new Date(Date.now() - 86400000).toISOString();
          const { count } = await admin.from('article_reads').select('article_id', { count: 'exact', head: true }).eq('user_id', job.user_id).gte('created_at', since);
          if ((count ?? 0) >= 25) { await retry(admin, job, 'Card allowance has not reset yet'); continue; }
          const html = emailFrame('Your next Good Press edition is ready.', 'Twenty-five fresh spaces on the newsstand.', '<p>Your free card allowance has refreshed. The newsroom has swept the floor, sharpened its pencils and opened the doors again.</p>', 'Read your refreshed edition', appUrl, unsubscribeUrl);
          await sendMail(recipient, 'Your Good Press cards are ready', html);
        } else {
          const ids = Array.isArray(job.payload?.article_ids) ? job.payload.article_ids : [];
          const { data: articles } = await admin.from('articles').select('id,title,category').in('id', ids).eq('status', 'published').order('published_at', { ascending: false }).limit(6);
          if (!articles?.length) { await complete(admin, job, 'skipped', recipient, 'No published articles remained in this batch'); skipped++; continue; }
          const list = articles.map(article => `<li style="margin:0 0 10px"><strong>${escapeHtml(article.title)}</strong><br><span style="color:#716c63;font:12px Arial,sans-serif;text-transform:uppercase">${escapeHtml(article.category)}</span></li>`).join('');
          const extra = ids.length > articles.length ? `<p>And ${ids.length - articles.length} more hopeful update${ids.length - articles.length === 1 ? '' : 's'}.</p>` : '';
          const html = emailFrame(`${ids.length} new Good Press update${ids.length === 1 ? '' : 's'} just arrived.`, 'Fresh from the good-news desk.', `<p>The newsroom found progress worth knowing:</p><ul style="padding-left:20px">${list}</ul>${extra}`, 'Read the latest edition', appUrl, unsubscribeUrl);
          await sendMail(recipient, `${ids.length} new Good Press update${ids.length === 1 ? '' : 's'}`, html);
        }

        await complete(admin, job, 'sent', recipient);
        sent++;
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Unknown delivery error';
        await retry(admin, job, message);
        failed++;
      }
    }
    return json({ enabled: true, claimed: (data ?? []).length, sent, skipped, failed });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Notification worker failed';
    return json({ error: message }, message === 'Unauthorized' ? 401 : 500);
  }
});

