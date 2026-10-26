-- Segment Good Press email notifications by reader plan.
-- Australia/Perth is UTC+8 year-round, so 04:00 UTC is 12:00 PM AWST.

alter table public.notification_preferences
  add column if not exists unread_reminders boolean not null default false;

grant update (unread_reminders) on public.notification_preferences to authenticated;

alter table public.notification_outbox
  drop constraint if exists notification_outbox_kind_check;

alter table public.notification_outbox
  add constraint notification_outbox_kind_check
  check (kind in ('auth', 'welcome', 'new_articles', 'card_reset', 'unread_reminder'));

create or replace function public.reader_has_unlimited_access(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.subscriptions subscription
    where subscription.user_id = p_user_id
      and subscription.status in ('active', 'trialing')
      and (subscription.current_period_end is null or subscription.current_period_end > now())
  );
$$;

create or replace function public.count_unread_stories(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.articles article
  where article.status::text = 'published'
    and (
      public.reader_has_unlimited_access(p_user_id)
      or coalesce(article.published_at, article.created_at) >= now() - interval '15 days'
    )
    and not exists (
      select 1 from public.article_reads reader_read
      where reader_read.user_id = p_user_id and reader_read.article_id = article.id
    )
    and not exists (
      select 1 from public.swipes reader_swipe
      where reader_swipe.user_id = p_user_id and reader_swipe.article_id = article.id
    );
$$;

revoke all on function public.reader_has_unlimited_access(uuid) from public, anon, authenticated;
revoke all on function public.count_unread_stories(uuid) from public, anon, authenticated;
grant execute on function public.reader_has_unlimited_access(uuid) to service_role;
grant execute on function public.count_unread_stories(uuid) to service_role;

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
      'unread_count', unread.unread_count
    ),
    now(),
    'subscriber_daily:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (
    select count(*)::integer as new_count
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
      'unread_count', unread.unread_count
    ),
    now(),
    'unread_reminder:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (
    select public.count_unread_stories(preference.user_id) as unread_count
  ) unread
  where preference.unread_reminders
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and unread.unread_count > 0
  on conflict (idempotency_key) do nothing;

  get diagnostics queued = row_count;
  return queued;
end;
$$;

revoke all on function public.queue_subscriber_daily_digests() from public, anon, authenticated;
revoke all on function public.queue_unread_story_reminders() from public, anon, authenticated;
grant execute on function public.queue_subscriber_daily_digests() to service_role;
grant execute on function public.queue_unread_story_reminders() to service_role;

-- Retire near-real-time article alerts and their unsent legacy batches.
drop trigger if exists articles_queue_email_notification on public.articles;

delete from public.notification_outbox
where kind = 'new_articles'
  and status = 'pending'
  and coalesce(payload->>'mode', '') <> 'subscriber_daily';

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job from cron.job
  where jobname = 'good-press-subscriber-daily-digest' limit 1;
  if existing_job is not null then perform cron.unschedule(existing_job); end if;

  select jobid into existing_job from cron.job
  where jobname = 'good-press-unread-reminders' limit 1;
  if existing_job is not null then perform cron.unschedule(existing_job); end if;
end;
$$;

select cron.schedule(
  'good-press-subscriber-daily-digest',
  '0 4 * * *',
  $schedule$select public.queue_subscriber_daily_digests();$schedule$
);

select cron.schedule(
  'good-press-unread-reminders',
  '0 4 * * 2,5',
  $schedule$select public.queue_unread_story_reminders();$schedule$
);

