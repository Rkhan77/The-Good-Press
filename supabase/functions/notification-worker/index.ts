import { adminClient, authEmailFrame, emailFrame, environment, escapeHtml, json, requireServiceRequest, sendMail } from '../_shared/email.ts';

type Job = {
  id: number;
  kind: 'auth' | 'welcome' | 'new_articles' | 'card_reset' | 'unread_reminder';
  user_id: string;
  payload: { article_ids?: number[]; recipient?: string; action?: string; token_hash?: string; token?: string; redirect_to?: string; mode?: string; unread_count?: number; new_count?: number; recent_titles?: string[] };
  attempts: number;
};

const dailyMessages = [
  { subject: 'Your daily dose of good things has arrived', heading: 'Good things have been happening.', line: 'The newsroom gathered today’s useful progress into one calmer place.' },
  { subject: 'Today’s good things are ready', heading: 'The good stuff made the paper.', line: 'A fresh edition is waiting, with less noise and more things worth knowing.' },
  { subject: 'A fresh dose of progress just landed', heading: 'Something good has been happening.', line: 'The presses have been busy finding constructive stories for your next read.' },
];

const unreadMessages = [
  { subject: 'A gentler scroll is waiting', heading: 'Doomscrolling called. We sent it to voicemail.', line: 'Endless bad news will not save the world. A few constructive stories may, however, help your attention recover.' },
  { subject: 'Your attention deserves better news', heading: 'Your attention span is not a lost cause.', line: 'A short visit to useful progress is kinder than another lap around the outrage carousel.' },
  { subject: 'There are good things you have not read yet', heading: 'The world will survive one less doomscroll.', line: 'Give your thumbs a healthier assignment and catch up on the good things that have been getting done.' },
];

function randomMessage<T>(messages: readonly T[]): T {
  const random = crypto.getRandomValues(new Uint32Array(1))[0];
  return messages[random % messages.length];
}

function pluralStories(count: number) {
  return `${count} ${count === 1 ? 'story' : 'stories'}`;
}

function numberedHeadlines(titles: unknown) {
  if (!Array.isArray(titles)) return '';
  const clean = [...new Set(titles.map(title => String(title ?? '').trim()).filter(Boolean))];
  if (!clean.length) return '';
  return `<p style="margin-bottom:8px"><strong>Recently added:</strong></p><ol style="margin:0 0 20px;padding-left:24px">${clean.map(title => `<li style="margin:0 0 8px">${escapeHtml(title)}</li>`).join('')}</ol>`;
}

const authMessages: Record<string, { subject: string; preheader: string; heading: string; copy: string; button: string }> = {
  signup: { subject: 'Confirm your Good Press account', preheader: 'Confirm your email to open your Good Edition.', heading: 'Confirm your place at the newsstand.', copy: '<p>One quick check and your Good Press account will be ready. Confirm this email address to start choosing the locations and stories that matter to you.</p>', button: 'Confirm my email' },
  recovery: { subject: 'Reset your Good Press password', preheader: 'Use this secure link to choose a new password.', heading: 'Let’s get you back into the newsroom.', copy: '<p>Someone requested a password reset for your Good Press account. Use the secure link below to choose a new password.</p>', button: 'Reset my password' },
  invite: { subject: 'You’re invited to The Good Press', preheader: 'Your invitation to the brighter side of the news.', heading: 'There’s a Good Edition waiting for you.', copy: '<p>You have been invited to join The Good Press—a calmer newsstand for progress, useful developments and stories worth supporting.</p>', button: 'Accept invitation' },
  magiclink: { subject: 'Your Good Press sign-in link', preheader: 'Use this secure link to sign in.', heading: 'Your newsstand door is open.', copy: '<p>Use the secure link below to sign in to The Good Press. It is temporary and can only be used for this request.</p>', button: 'Sign in to The Good Press' },
  reauthentication: { subject: 'Confirm it’s you', preheader: 'Complete your Good Press security check.', heading: 'A quick security check.', copy: '<p>Use the secure link below to confirm it is really you before continuing with this account change.</p>', button: 'Confirm it’s me' },
  email_change: { subject: 'Confirm your Good Press email change', preheader: 'Confirm this address for your Good Press account.', heading: 'Confirm your new email address.', copy: '<p>Use the secure link below to confirm this email address for your Good Press account.</p>', button: 'Confirm email change' },
  hook_test: { subject: 'Good Press authentication email test', preheader: 'The live authentication email route is working.', heading: 'The postman found the newsroom.', copy: '<p>This private test confirms that Supabase Auth can queue an email and Resend can deliver it from <strong>no-reply@goodpress.au</strong>.</p>', button: 'Open The Good Press' },
};

function authVerificationUrl(projectUrl: string, payload: Job['payload'], appUrl: string) {
  if (payload.action === 'hook_test') return appUrl;
  return `${projectUrl}/auth/v1/verify?token=${encodeURIComponent(payload.token_hash ?? '')}&type=${encodeURIComponent(payload.action ?? 'magiclink')}&redirect_to=${encodeURIComponent(payload.redirect_to || appUrl)}`;
}

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

async function currentUnreadCount(admin: ReturnType<typeof adminClient>, userId: string, fallback = 0) {
  const { data, error } = await admin.rpc('count_unread_stories', { p_user_id: userId });
  if (!error && Number.isFinite(Number(data))) return Math.max(0, Math.floor(Number(data)));
  return Math.max(0, Math.floor(Number(fallback) || 0));
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
        const [{ data: preference }, { data: authData }, { data: subscription }] = await Promise.all([
          admin.from('notification_preferences').select('new_articles,card_reset,unread_reminders,unsubscribed_at,unsubscribe_token').eq('user_id', job.user_id).maybeSingle(),
          admin.auth.admin.getUserById(job.user_id),
          admin.from('subscriptions').select('status,current_period_end').eq('user_id', job.user_id).maybeSingle(),
        ]);
        recipient = job.kind === 'auth' ? (job.payload?.recipient ?? '') : (authData.user?.email ?? '');
        const unlimited = Boolean(subscription && ['active', 'trialing'].includes(subscription.status) && (!subscription.current_period_end || new Date(subscription.current_period_end) > new Date()));
        const allowed = job.kind === 'auth'
          ? Boolean(recipient)
          : Boolean(preference && !preference.unsubscribed_at && (
            job.kind === 'welcome'
            || (job.kind === 'new_articles' && unlimited && preference.new_articles)
            || (job.kind === 'card_reset' && !unlimited && preference.card_reset)
            || (job.kind === 'unread_reminder' && preference.unread_reminders)
          ));
        if (!allowed || !recipient) { await complete(admin, job, 'skipped', recipient, 'Reader is not eligible or opted in'); skipped++; continue; }

        if (job.kind === 'auth') {
          const action = job.payload?.action ?? 'magiclink';
          const message = authMessages[action] ?? authMessages.magiclink;
          const html = authEmailFrame(message.preheader, message.heading, message.copy, message.button, authVerificationUrl(projectUrl, job.payload, appUrl));
          await sendMail(recipient, message.subject, html);
        } else if (job.kind === 'welcome') {
          if (!preference) throw new Error('Notification preference record is missing');
          const unsubscribeUrl = `${projectUrl}/functions/v1/unsubscribe?token=${encodeURIComponent(preference.unsubscribe_token)}`;
          const html = emailFrame(
            'Your good-news edition is ready.',
            'Welcome to the brighter side of the news.',
            '<p>Thanks for joining The Good Press, where useful progress gets the front page and the news does not pick a fight with your mood.</p><p>Choose the locations and topics you care about, then support the stories you want to see more of. Your personal edition will learn what matters to you—quietly, helpfully, and without shouting across the newsroom.</p><p><strong>See you at the newsstand,<br>The GP Team</strong></p>',
            'Build your Good Edition',
            appUrl,
            unsubscribeUrl,
            undefined,
            'welcome@goodpress.au',
          );
          await sendMail(recipient, 'Welcome to The Good Press', html, { fromEmail: 'welcome@goodpress.au' });
        } else if (job.kind === 'card_reset') {
          if (!preference) throw new Error('Notification preference record is missing');
          const unsubscribeUrl = `${projectUrl}/functions/v1/unsubscribe?token=${encodeURIComponent(preference.unsubscribe_token)}`;
          const since = new Date(Date.now() - 86400000).toISOString();
          const { count } = await admin.from('article_reads').select('article_id', { count: 'exact', head: true }).eq('user_id', job.user_id).gte('created_at', since);
          if ((count ?? 0) >= 25) { await retry(admin, job, 'Card allowance has not reset yet'); continue; }
          const unreadCount = await currentUnreadCount(admin, job.user_id, job.payload?.unread_count);
          if (!unreadCount) { await complete(admin, job, 'skipped', recipient, 'No unread stories are available'); skipped++; continue; }
          const message = randomMessage(dailyMessages);
          const html = emailFrame(
            `${pluralStories(unreadCount)} are waiting in your refreshed edition.`,
            message.heading,
            `<p>${message.line}</p><p>Your 25-card edition has refreshed, with <strong>${pluralStories(unreadCount)}</strong> waiting to be read.</p>`,
            'Read more',
            appUrl,
            unsubscribeUrl,
            unreadCount,
          );
          await sendMail(recipient, message.subject, html);
        } else if (job.kind === 'new_articles') {
          if (!preference) throw new Error('Notification preference record is missing');
          const unsubscribeUrl = `${projectUrl}/functions/v1/unsubscribe?token=${encodeURIComponent(preference.unsubscribe_token)}`;
          const unreadCount = await currentUnreadCount(admin, job.user_id, job.payload?.unread_count);
          const newCount = Math.min(unreadCount, Math.max(0, Math.floor(Number(job.payload?.new_count) || 0)));
          if (!unreadCount || !newCount) { await complete(admin, job, 'skipped', recipient, 'No unread new stories are available'); skipped++; continue; }
          const message = randomMessage(dailyMessages);
          const headlines = numberedHeadlines(job.payload?.recent_titles);
          const html = emailFrame(
            `${pluralStories(newCount)} joined The Good Press today.`,
            message.heading,
            `<p>${message.line}</p><p><strong>${pluralStories(newCount)}</strong> arrived today, and your edition has <strong>${pluralStories(unreadCount)}</strong> waiting in total.</p>${headlines}`,
            'Login',
            appUrl,
            unsubscribeUrl,
            unreadCount,
          );
          await sendMail(recipient, message.subject, html);
        } else {
          if (!preference) throw new Error('Notification preference record is missing');
          const unsubscribeUrl = `${projectUrl}/functions/v1/unsubscribe?token=${encodeURIComponent(preference.unsubscribe_token)}`;
          const unreadCount = await currentUnreadCount(admin, job.user_id, job.payload?.unread_count);
          if (!unreadCount) { await complete(admin, job, 'skipped', recipient, 'No unread stories are available'); skipped++; continue; }
          const message = randomMessage(unreadMessages);
          const headlines = numberedHeadlines(job.payload?.recent_titles);
          const subscribePrompt = unlimited ? '' : `<div style="margin:24px 0 0;padding:18px;border:1px solid #b7b0a1"><p style="margin:0 0 12px"><strong>Want more of this?</strong><br>Subscribe for unlimited stories and a fresh inspiring digest every day.</p><a href="${escapeHtml(`${appUrl}/?subscribe=1`)}" style="display:inline-block;background:#e74a32;color:#fff;padding:11px 15px;text-decoration:none;font:800 13px Arial,sans-serif">Subscribe</a></div>`;
          const html = emailFrame(
            `${pluralStories(unreadCount)} are waiting for a calmer scroll.`,
            message.heading,
            `<p>${message.line}</p><p>You have <strong>${pluralStories(unreadCount)}</strong> waiting in The Good Press.</p>${headlines}`,
            'Login',
            appUrl,
            unsubscribeUrl,
            unreadCount,
            'no-reply@goodpress.au',
            subscribePrompt,
            false,
          );
          await sendMail(recipient, message.subject, html);
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

