-- Free signed-in readers should see unread counts within their 25-card edition.
-- Unlimited subscribers continue to see their complete unread-story count.

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
  daily_allowance as (
    select greatest(
      0,
      25 - (count(*) filter (where reader_read.created_at >= now() - interval '24 hours'))::integer
    ) as remaining_cards
    from public.article_reads reader_read
    where reader_read.user_id = p_user_id
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
        select 1
        from public.article_reads reader_read
        where reader_read.user_id = p_user_id
          and reader_read.article_id = article.id
      )
      and not exists (
        select 1
        from public.swipes reader_swipe
        where reader_swipe.user_id = p_user_id
          and reader_swipe.article_id = article.id
      )
  )
  select case
    when access.unlimited then available.unread_count
    else least(allowance.remaining_cards, available.unread_count)
  end
  from reader_access access
  cross join daily_allowance allowance
  cross join available_stories available;
$$;

revoke all on function public.count_unread_stories(uuid) from public, anon, authenticated;
grant execute on function public.count_unread_stories(uuid) to service_role;

