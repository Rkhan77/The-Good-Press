-- Give opted-in readers a compact unread digest three times each week.
-- Australia/Perth is UTC+8 year-round, so 04:00 UTC is 12:00 PM AWST.

create or replace function public.queue_unread_story_reminders()
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
    'unread_reminder',
    preference.user_id,
    jsonb_build_object(
      'mode', 'unread_reminder',
      'unread_count', unread.unread_count,
      'recent_titles', digest.recent_titles
    ),
    now(),
    'unread_reminder:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (
    select public.count_unread_stories(preference.user_id) as unread_count
  ) unread
  cross join lateral (
    select coalesce(
      jsonb_agg(recent.title order by recent.sort_time desc),
      '[]'::jsonb
    ) as recent_titles
    from (
      select
        article.title,
        coalesce(article.published_at, article.created_at) as sort_time
      from public.articles article
      where article.status::text = 'published'
        and (
          public.reader_has_unlimited_access(preference.user_id)
          or coalesce(article.published_at, article.created_at) >= now() - interval '15 days'
        )
        and not exists (
          select 1 from public.article_reads reader_read
          where reader_read.user_id = preference.user_id
            and reader_read.article_id = article.id
        )
        and not exists (
          select 1 from public.swipes reader_swipe
          where reader_swipe.user_id = preference.user_id
            and reader_swipe.article_id = article.id
        )
      order by coalesce(article.published_at, article.created_at) desc
      limit 5
    ) recent
  ) digest
  where preference.unread_reminders
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and unread.unread_count > 0
    and jsonb_array_length(digest.recent_titles) > 0
  on conflict (idempotency_key) do nothing;

  get diagnostics queued = row_count;
  return queued;
end;
$$;

revoke all on function public.queue_unread_story_reminders() from public, anon, authenticated;
grant execute on function public.queue_unread_story_reminders() to service_role;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'good-press-unread-reminders'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end;
$$;

select cron.schedule(
  'good-press-unread-reminders',
  '0 4 * * 1,3,5',
  $schedule$select public.queue_unread_story_reminders();$schedule$
);
