-- Supporting a story is a distinct signal from progressing past it.
alter table public.user_agendas
  add column if not exists support_scores jsonb not null default '{}'::jsonb;

create table if not exists public.article_supports (
  user_id uuid not null references auth.users (id) on delete cascade,
  article_id bigint not null references public.articles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create index if not exists article_supports_article_idx
  on public.article_supports (article_id);

alter table public.article_supports enable row level security;

create policy "Readers can see their own story support"
on public.article_supports for select
to authenticated
using ((select auth.uid()) = user_id);

-- The app writes through the function below, rather than directly to this table.
revoke insert, update, delete on public.article_supports from authenticated;

create or replace view public.article_support_counts
with (security_invoker = false)
as
select article_id, count(*)::integer as supporter_count
from public.article_supports
group by article_id;

grant select on public.article_support_counts to anon, authenticated;

create or replace function public.record_article_support(p_article_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := auth.uid();
  cat text;
  inserted_rows integer := 0;
  scores jsonb;
  support_count integer;
begin
  if u is null then raise exception 'Authentication required'; end if;
  select category into cat from articles where id = p_article_id and status = 'published';
  if cat is null then raise exception 'Published article not found'; end if;

  insert into user_agendas(user_id) values (u) on conflict (user_id) do nothing;
  insert into article_supports(user_id, article_id) values (u, p_article_id)
  on conflict (user_id, article_id) do nothing;
  get diagnostics inserted_rows = row_count;

  if inserted_rows > 0 then
    select support_scores into scores from user_agendas where user_id = u for update;
    scores := jsonb_set(
      coalesce(scores, '{}'::jsonb),
      array[cat],
      to_jsonb(coalesce((scores ->> cat)::integer, 0) + 1),
      true
    );
    update user_agendas
    set support_scores = scores, updated_at = now()
    where user_id = u;
  end if;

  select count(*)::integer into support_count
  from article_supports where article_id = p_article_id;

  return jsonb_build_object(
    'support_count', support_count,
    'agenda', (select jsonb_build_object('support_scores', support_scores, 'preferred_categories', preferred_categories, 'blocked_categories', blocked_categories) from user_agendas where user_id = u)
  );
end;
$$;

grant execute on function public.record_article_support(bigint) to authenticated;

-- Moving past a card is tracked separately from supporting it. This preserves
-- the free daily allowance without treating a swipe as a preference signal.
create table if not exists public.article_reads (
  user_id uuid not null references auth.users (id) on delete cascade,
  article_id bigint not null references public.articles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create index if not exists article_reads_user_created_idx
  on public.article_reads (user_id, created_at);

alter table public.article_reads enable row level security;

create policy "Readers can see their own card progress"
on public.article_reads for select
to authenticated
using ((select auth.uid()) = user_id);

revoke insert, update, delete on public.article_reads from authenticated;

create or replace function public.record_card_read(p_article_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := auth.uid();
  is_unlimited boolean;
  used_cards integer;
  next_feed_at timestamptz;
begin
  if u is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from articles where id = p_article_id and status = 'published') then
    raise exception 'Published article not found';
  end if;

  insert into article_reads(user_id, article_id) values (u, p_article_id)
  on conflict (user_id, article_id) do update set created_at = excluded.created_at;

  select exists(
    select 1 from subscriptions
    where user_id = u
      and status in ('active', 'trialing')
      and (current_period_end is null or current_period_end > now())
  ) into is_unlimited;

  select count(*), min(created_at) + interval '24 hours'
  into used_cards, next_feed_at
  from article_reads
  where user_id = u and created_at >= now() - interval '24 hours';

  return jsonb_build_object(
    'remaining_cards', case when is_unlimited then null else greatest(0, 25 - used_cards) end,
    'next_feed_at', case when is_unlimited then null else next_feed_at end
  );
end;
$$;

grant execute on function public.record_card_read(bigint) to authenticated;
