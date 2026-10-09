-- Saved stories belong only to the signed-in reader who bookmarked them.
create table public.saved_articles (
  user_id uuid not null references auth.users (id) on delete cascade,
  article_id bigint not null references public.articles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create index saved_articles_user_created_idx
  on public.saved_articles (user_id, created_at desc);

alter table public.saved_articles enable row level security;

create policy "Users can read their own saved articles"
on public.saved_articles for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Users can save their own articles"
on public.saved_articles for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Users can remove their own saved articles"
on public.saved_articles for delete
to authenticated
using ((select auth.uid()) = user_id);

grant select, insert, delete on public.saved_articles to authenticated;
