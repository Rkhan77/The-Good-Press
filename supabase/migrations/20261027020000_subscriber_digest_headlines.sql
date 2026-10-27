-- Include the titles of each subscriber's newly available stories in the
-- midday digest payload. The worker renders them as a numbered list.

create or replace function public.queue_subscriber_daily_digests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  queued integer;
  perth_day text := to_char(timezone('Australia/Perth', now()), 'YYYY-MM-DD');
begin
  insert into public.notification_outbox (
    kind,
    user_id,
    payload,
    scheduled_for,
    idempotency_key
  )
  select
    'new_articles',
    preference.user_id,
    jsonb_build_object(
      'mode', 'subscriber_daily',
      'new_count', fresh.new_count,
      'unread_count', unread.unread_count,
      'recent_titles', fresh.recent_titles
    ),
    now(),
    'subscriber_daily:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (
    select
      count(*)::integer as new_count,
      coalesce(
        jsonb_agg(article.title order by coalesce(article.published_at, article.created_at) desc)
          filter (where nullif(trim(article.title), '') is not null),
        '[]'::jsonb
      ) as recent_titles
    from public.articles article
    where article.status::text = 'published'
      and coalesce(article.published_at, article.created_at) >= now() - interval '24 hours'
      and not exists (
        select 1 from public.article_reads reader_read
        where reader_read.user_id = preference.user_id and reader_read.article_id = article.id
      )
      and not exists (
        select 1 from public.swipes reader_swipe
        where reader_swipe.user_id = preference.user_id and reader_swipe.article_id = article.id
      )
  ) fresh
  cross join lateral (
    select public.count_unread_stories(preference.user_id) as unread_count
  ) unread
  where preference.new_articles
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and public.reader_has_unlimited_access(preference.user_id)
    and fresh.new_count > 0
    and unread.unread_count > 0
  on conflict (idempotency_key) do nothing;

  get diagnostics queued = row_count;
  return queued;
end;
$$;

revoke all on function public.queue_subscriber_daily_digests() from public, anon, authenticated;
grant execute on function public.queue_subscriber_daily_digests() to service_role;
