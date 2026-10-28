-- Start a free reader's 24-hour reset only after all 25 edition cards are read.
-- Subscribers receive their daily digest only, not the separate unread reminder.

create table if not exists public.reader_card_cycles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  cycle_started_at timestamptz not null default now(),
  exhausted_at timestamptz,
  resets_at timestamptz,
  updated_at timestamptz not null default now(),
  check ((exhausted_at is null and resets_at is null) or (exhausted_at is not null and resets_at is not null))
);

alter table public.reader_card_cycles enable row level security;
revoke all on public.reader_card_cycles from anon, authenticated;

insert into public.reader_card_cycles (user_id, cycle_started_at, exhausted_at, resets_at)
select
  reader_read.user_id,
  min(reader_read.created_at),
  case when count(*) >= 25 then max(reader_read.created_at) end,
  case when count(*) >= 25 then max(reader_read.created_at) + interval '24 hours' end
from public.article_reads reader_read
where reader_read.created_at >= now() - interval '24 hours'
group by reader_read.user_id
on conflict (user_id) do nothing;

create or replace function public.reader_cards_remaining(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.reader_has_unlimited_access(p_user_id) then null
    when cycle.resets_at is not null and cycle.resets_at > now() then 0
    when cycle.resets_at is not null and cycle.resets_at <= now() then 25
    else greatest(
      0,
      25 - (
        select count(*)::integer
        from public.article_reads reader_read
        where reader_read.user_id = p_user_id
          and reader_read.created_at >= coalesce(cycle.cycle_started_at, now())
      )
    )
  end
  from (select 1) singleton
  left join public.reader_card_cycles cycle on cycle.user_id = p_user_id;
$$;

create or replace function public.count_unread_stories(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  with reader_access as (
    select public.reader_has_unlimited_access(p_user_id) as unlimited
  ),
  available_stories as (
    select count(*)::integer as unread_count
    from public.articles article
    cross join reader_access access
    where article.status::text = 'published'
      and (
        access.unlimited
        or coalesce(article.published_at, article.created_at) >= now() - interval '15 days'
      )
      and not exists (
        select 1 from public.article_reads reader_read
        where reader_read.user_id = p_user_id
          and reader_read.article_id = article.id
      )
      and not exists (
        select 1 from public.swipes reader_swipe
        where reader_swipe.user_id = p_user_id
          and reader_swipe.article_id = article.id
      )
  )
  select case
    when access.unlimited then available.unread_count
    else least(public.reader_cards_remaining(p_user_id), available.unread_count)
  end
  from reader_access access
  cross join available_stories available;
$$;

create or replace function public.get_reader_card_progress()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := auth.uid();
  cycle public.reader_card_cycles;
  remaining integer;
begin
  if u is null then raise exception 'Authentication required'; end if;

  insert into public.reader_card_cycles (user_id) values (u)
  on conflict (user_id) do nothing;

  select * into cycle from public.reader_card_cycles where user_id = u for update;

  if cycle.resets_at is not null and cycle.resets_at <= now() then
    update public.reader_card_cycles
    set cycle_started_at = cycle.resets_at,
        exhausted_at = null,
        resets_at = null,
        updated_at = now()
    where user_id = u
    returning * into cycle;
  end if;

  remaining := public.reader_cards_remaining(u);
  return jsonb_build_object(
    'remaining_cards', remaining,
    'next_feed_at', cycle.resets_at,
    'cycle_started_at', cycle.cycle_started_at
  );
end;
$$;

create or replace function public.record_card_read(p_article_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := auth.uid();
  is_unlimited boolean;
  cycle public.reader_card_cycles;
  used_cards integer;
begin
  if u is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.articles where id = p_article_id and status::text = 'published') then
    raise exception 'Published article not found';
  end if;

  is_unlimited := public.reader_has_unlimited_access(u);
  if is_unlimited then
    insert into public.article_reads (user_id, article_id) values (u, p_article_id)
    on conflict (user_id, article_id) do update set created_at = excluded.created_at;
    return jsonb_build_object('remaining_cards', null, 'next_feed_at', null, 'cycle_started_at', null);
  end if;

  insert into public.reader_card_cycles (user_id) values (u)
  on conflict (user_id) do nothing;
  select * into cycle from public.reader_card_cycles where user_id = u for update;

  if cycle.resets_at is not null and cycle.resets_at <= now() then
    update public.reader_card_cycles
    set cycle_started_at = cycle.resets_at,
        exhausted_at = null,
        resets_at = null,
        updated_at = now()
    where user_id = u
    returning * into cycle;
  elsif cycle.resets_at is not null then
    return jsonb_build_object('remaining_cards', 0, 'next_feed_at', cycle.resets_at, 'cycle_started_at', cycle.cycle_started_at);
  end if;

  select count(*)::integer into used_cards
  from public.article_reads reader_read
  where reader_read.user_id = u and reader_read.created_at >= cycle.cycle_started_at;

  if used_cards >= 25 then
    return jsonb_build_object('remaining_cards', 0, 'next_feed_at', cycle.resets_at, 'cycle_started_at', cycle.cycle_started_at);
  end if;

  insert into public.article_reads (user_id, article_id) values (u, p_article_id)
  on conflict (user_id, article_id) do update set created_at = excluded.created_at;

  select count(*)::integer into used_cards
  from public.article_reads reader_read
  where reader_read.user_id = u and reader_read.created_at >= cycle.cycle_started_at;

  if used_cards >= 25 then
    update public.reader_card_cycles
    set exhausted_at = now(), resets_at = now() + interval '24 hours', updated_at = now()
    where user_id = u
    returning * into cycle;

    if exists (
      select 1 from public.notification_preferences preference
      where preference.user_id = u
        and preference.card_reset
        and preference.consented_at is not null
        and preference.unsubscribed_at is null
    ) then
      insert into public.notification_outbox (kind, user_id, scheduled_for, idempotency_key)
      values ('card_reset', u, cycle.resets_at, 'card_reset:' || u::text || ':' || extract(epoch from cycle.resets_at)::bigint::text)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;

  return jsonb_build_object(
    'remaining_cards', greatest(0, 25 - used_cards),
    'next_feed_at', cycle.resets_at,
    'cycle_started_at', cycle.cycle_started_at
  );
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
    jsonb_build_object('mode', 'unread_reminder', 'unread_count', unread.unread_count, 'recent_titles', digest.recent_titles),
    now(),
    'unread_reminder:' || preference.user_id::text || ':' || perth_day
  from public.notification_preferences preference
  cross join lateral (select public.count_unread_stories(preference.user_id) as unread_count) unread
  cross join lateral (
    select coalesce(jsonb_agg(recent.title order by recent.sort_time desc), '[]'::jsonb) as recent_titles
    from (
      select article.title, coalesce(article.published_at, article.created_at) as sort_time
      from public.articles article
      where article.status::text = 'published'
        and coalesce(article.published_at, article.created_at) >= now() - interval '15 days'
        and not exists (
          select 1 from public.article_reads reader_read
          where reader_read.user_id = preference.user_id and reader_read.article_id = article.id
        )
        and not exists (
          select 1 from public.swipes reader_swipe
          where reader_swipe.user_id = preference.user_id and reader_swipe.article_id = article.id
        )
      order by coalesce(article.published_at, article.created_at) desc
      limit 5
    ) recent
  ) digest
  where preference.unread_reminders
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
    and not public.reader_has_unlimited_access(preference.user_id)
    and unread.unread_count > 0
    and jsonb_array_length(digest.recent_titles) > 0
  on conflict (idempotency_key) do nothing;

  get diagnostics queued = row_count;
  return queued;
end;
$$;

update public.notification_preferences preference
set unread_reminders = false, updated_at = now()
where public.reader_has_unlimited_access(preference.user_id) and preference.unread_reminders;

delete from public.notification_outbox outbox
where outbox.kind = 'unread_reminder'
  and outbox.status = 'pending'
  and public.reader_has_unlimited_access(outbox.user_id);

update public.notification_outbox outbox
set scheduled_for = cycle.resets_at, updated_at = now()
from public.reader_card_cycles cycle
where outbox.kind = 'card_reset'
  and outbox.status = 'pending'
  and outbox.user_id = cycle.user_id
  and cycle.resets_at is not null;

revoke all on function public.reader_cards_remaining(uuid) from public, anon, authenticated;
revoke all on function public.count_unread_stories(uuid) from public, anon, authenticated;
revoke all on function public.get_reader_card_progress() from public, anon;
revoke all on function public.record_card_read(bigint) from public, anon;
revoke all on function public.queue_unread_story_reminders() from public, anon, authenticated;
grant execute on function public.reader_cards_remaining(uuid) to service_role;
grant execute on function public.count_unread_stories(uuid) to service_role;
grant execute on function public.get_reader_card_progress() to authenticated;
grant execute on function public.record_card_read(bigint) to authenticated;
grant execute on function public.queue_unread_story_reminders() to service_role;

