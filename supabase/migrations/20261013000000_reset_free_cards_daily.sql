-- Free readers receive up to 25 new card choices in each rolling 24-hour window.
create or replace function public.record_swipe(p_article_id bigint, p_direction public.swipe_direction)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  old public.swipe_direction;
  cat text;
  scores jsonb;
  delta int;
  value int;
  pref text[];
  blocked text[];
  unlimited boolean;
  used_cards int;
begin
  if u is null then raise exception 'Authentication required'; end if;
  select category into cat from articles where id = p_article_id and status = 'published';
  if cat is null then raise exception 'Published article not found'; end if;

  insert into user_agendas(user_id) values(u) on conflict(user_id) do nothing;
  select direction into old from swipes where user_id = u and article_id = p_article_id;
  select exists(
    select 1 from subscriptions
    where user_id = u
      and status in ('active', 'trialing')
      and (current_period_end is null or current_period_end > now())
  ) into unlimited;

  if old is null and not unlimited then
    select count(*) into used_cards from swipes
    where user_id = u and created_at >= now() - interval '24 hours';
    if used_cards >= 25 then raise exception 'Free daily card limit reached'; end if;
  end if;

  insert into swipes(user_id, article_id, direction) values(u, p_article_id, p_direction)
  on conflict(user_id, article_id) do update set direction = excluded.direction;

  select preference_scores into scores from user_agendas where user_id = u for update;
  delta := (case p_direction when 'right' then 1 else -1 end) - (case old when 'right' then 1 when 'left' then -1 else 0 end);
  value := coalesce((scores->>cat)::int, 0) + delta;
  scores := jsonb_set(coalesce(scores, '{}'::jsonb), array[cat], to_jsonb(value), true);
  select coalesce(array_agg(key order by key) filter(where val::int >= 10), '{}'), coalesce(array_agg(key order by key) filter(where val::int <= -3), '{}') into pref, blocked from jsonb_each_text(scores) x(key, val);
  update user_agendas set preference_scores = scores, preferred_categories = pref, blocked_categories = blocked, updated_at = now() where user_id = u;
  return (select jsonb_build_object('preference_scores', preference_scores, 'preferred_categories', preferred_categories, 'blocked_categories', blocked_categories) from user_agendas where user_id = u);
end $$;
