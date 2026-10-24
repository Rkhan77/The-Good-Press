import { adminClient, json, requireServiceRequest } from '../_shared/email.ts';

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    await requireServiceRequest(request);
    const body = await request.json().catch(() => ({}));
    const articleIds = Array.isArray(body.article_ids) ? [...new Set(body.article_ids.map(Number).filter(Number.isSafeInteger))] : [];
    if (!articleIds.length) return json({ error: 'article_ids must contain at least one article ID' }, 400);
    const { data, error } = await adminClient().rpc('queue_article_email_notifications', { p_article_ids: articleIds });
    if (error) throw error;
    return json({ queued: Number(data ?? 0), article_ids: articleIds });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Could not queue notifications';
    return json({ error: message }, message === 'Unauthorized' ? 401 : 500);
  }
});

