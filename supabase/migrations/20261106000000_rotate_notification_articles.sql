-- Prevent daily subscriber digests and free-reader unread reminders from
-- repeating an article that has already appeared in either email stream.
-- Email presentation is unchanged; only article selection is rotated.

create table if not exists public.notification_article_history (
  user_id uuid not null references auth.users (id) on delete cascade,
  article_id bigint not null references public.articles (id) on delete cascade,
  first_outbox_id bigint references public.notification_outbox (id) on delete set null,
  first_kind text not null check (first_kind in ('new_articles', 'unread_reminder')),
  sent_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create index if not exists notification_article_history_user_sent_idx
  on public.notification_article_history (user_id, sent_at desc);

alter table public.notification_article_history enable row level security;
revoke all on public.notification_article_history from anon, authenticated;

create or replace function public.capture_notification_article_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'sent'
     and old.status is distinct from new.status
     and new.kind in ('new_articles', 'unread_reminder') then
    insert into public.notification_article_history (
      user_id,
      article_id,
      first_outbox_id,
      first_kind,
      sent_at
    )
    select
      new.user_id,
      article_id.value::bigint,
      new.id,
      new.kind,
      coalesce(new.sent_at, now())
    from jsonb_array_elements_text(coalesce(new.payload->'article_ids', '[]'::jsonb)) article_id(value)
    where article_id.value ~ '^[0-9]+$'
    on conflict (user_id, article_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists notification_outbox_capture_article_history on public.notification_outbox;
create trigger notification_outbox_capture_article_history
after update of status on public.notification_outbox
for each row execute function public.capture_notification_article_history();

-- Seed the history from sent emails created before article IDs were included.
insert into public.notification_article_history (
  user_id,
  article_id,
  first_outbox_id,
  first_kind,
  sent_at
)
select distinct on (outbox.user_id, article.id)
  outbox.user_id,
  article.id,
  outbox.id,
  outbox.kind,
  coalesce(outbox.sent_at, outbox.updated_at, outbox.created_at)
from public.notification_outbox outbox
cross join lateral jsonb_array_elements_text(coalesce(outbox.payload->'recent_titles', '[]'::jsonb)) delivered_title(value)
join public.articles article on article.title = delivered_title.value
where outbox.status = 'sent'
  and outbox.kind in ('new_articles', 'unread_reminder')
order by outbox.user_id, article.id, coalesce(outbox.sent_at, outbox.updated_at, outbox.created_at)
on conflict (user_id, article_id) do nothing;

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
      'article_ids', digest.article_ids,
      'recent_titles', digest.recent_titles,
      'recent_articles', digest.recent_articles
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
        where reader_read.user_id = preference.user_id
          and reader_read.article_id = article.id
      )
      and not exists (
        select 1 from public.swipes reader_swipe
        where reader_swipe.user_id = preference.user_id
          and reader_swipe.article_id = article.id
      )
  ) fresh
  cross join lateral (
    select
      coalesce(jsonb_agg(candidate.id order by candidate.sort_time desc), '[]'::jsonb) as article_ids,
      coalesce(jsonb_agg(candidate.title order by candidate.sort_time desc), '[]'::jsonb) as recent_titles,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'title', candidate.title,
            'brief', case
              when nullif(trim(regexp_replace(coalesce(candidate.content, ''), '\s+', ' ', 'g')), '') is null
                then 'Open the story to read the full update.'
              when length(trim(regexp_replace(candidate.content, '\s+', ' ', 'g'))) > 220
                then left(trim(regexp_replace(candidate.content, '\s+', ' ', 'g')), 217) || '…'
              else trim(regexp_replace(candidate.content, '\s+', ' ', 'g'))
            end
          )
          order by candidate.sort_time desc
        ),
        '[]'::jsonb
      ) as recent_articles
    from (
      select
        article.id,
        article.title,
        article.content,
        coalesce(article.published_at, article.created_at) as sort_time
      from public.articles article
      where article.status::text = 'published'
        and nullif(trim(article.title), '') is not null
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
        and not exists (
          select 1 from public.notification_article_history history
          where history.user_id = preference.user_id
            and history.article_id = article.id
        )
        and not exists (
          select 1 from public.notification_outbox reserved
          where reserved.user_id = preference.user_id
            and reserved.kind in ('new_articles', 'unread_reminder')
            and reserved.status in ('pending', 'processing')
            and (
              coalesce(reserved.payload->'article_ids', '[]'::jsonb) @> jsonb_build_array(article.id)
              or coalesce(reserved.payload->'recent_titles', '[]'::jsonb) ? article.title
            )
        )
      order by coalesce(article.published_at, article.created_at) desc
      limit 5
    ) candidate
  ) digest
  cross join lateral (
    select public.count_unread_stories(preference.user_id) as unread_count
  ) unread
  where preference.new_articles
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and public.reader_has_unlimited_access(preference.user_id)
    and fresh.new_count > 0
    and unread.unread_count > 0
    and jsonb_array_length(digest.article_ids) > 0
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
  insert into public.notification_outbox (kind, user_id, payload, scheduled_for, idempotency_key)
  select
    'unread_reminder',
    preference.user_id,
    jsonb_build_object(
      'mode', 'unread_reminder',
      'unread_count', unread.unread_count,
      'article_ids', digest.article_ids,
      'recent_titles', digest.recent_titles
    ),
    now(),
    'unread_reminder:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (select public.count_unread_stories(preference.user_id) as unread_count) unread
  cross join lateral (
    select
      coalesce(jsonb_agg(candidate.id order by candidate.sort_time desc), '[]'::jsonb) as article_ids,
      coalesce(jsonb_agg(candidate.title order by candidate.sort_time desc), '[]'::jsonb) as recent_titles
    from (
      select
        article.id,
        article.title,
        coalesce(article.published_at, article.created_at) as sort_time
      from public.articles article
      where article.status::text = 'published'
        and nullif(trim(article.title), '') is not null
        and coalesce(article.published_at, article.created_at) >= now() - interval '15 days'
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
        and not exists (
          select 1 from public.notification_article_history history
          where history.user_id = preference.user_id
            and history.article_id = article.id
        )
        and not exists (
          select 1 from public.notification_outbox reserved
          where reserved.user_id = preference.user_id
            and reserved.kind in ('new_articles', 'unread_reminder')
            and reserved.status in ('pending', 'processing')
            and (
              coalesce(reserved.payload->'article_ids', '[]'::jsonb) @> jsonb_build_array(article.id)
              or coalesce(reserved.payload->'recent_titles', '[]'::jsonb) ? article.title
            )
        )
      order by coalesce(article.published_at, article.created_at) desc
      limit 5
    ) candidate
  ) digest
  where preference.unread_reminders
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and not public.reader_has_unlimited_access(preference.user_id)
    and unread.unread_count > 0
    and jsonb_array_length(digest.article_ids) > 0
  on conflict (idempotency_key) do nothing;

  get diagnostics queued = row_count;
  return queued;
end;
$$;

revoke all on function public.capture_notification_article_history() from public, anon, authenticated;
revoke all on function public.queue_subscriber_daily_digests() from public, anon, authenticated;
revoke all on function public.queue_unread_story_reminders() from public, anon, authenticated;
grant execute on function public.queue_subscriber_daily_digests() to service_role;
grant execute on function public.queue_unread_story_reminders() to service_role;
