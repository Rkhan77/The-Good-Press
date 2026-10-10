-- Saved news is part of the paid Good Reader Edition.
drop policy if exists "Users can read their own saved articles" on public.saved_articles;
drop policy if exists "Users can save their own articles" on public.saved_articles;
drop policy if exists "Users can remove their own saved articles" on public.saved_articles;

create policy "Subscribers can read their own saved articles"
on public.saved_articles for select
to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.subscriptions
    where user_id = (select auth.uid())
      and status in ('active', 'trialing')
      and (current_period_end is null or current_period_end > now())
  )
);

create policy "Subscribers can save their own articles"
on public.saved_articles for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.subscriptions
    where user_id = (select auth.uid())
      and status in ('active', 'trialing')
      and (current_period_end is null or current_period_end > now())
  )
);

create policy "Subscribers can remove their own saved articles"
on public.saved_articles for delete
to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1 from public.subscriptions
    where user_id = (select auth.uid())
      and status in ('active', 'trialing')
      and (current_period_end is null or current_period_end > now())
  )
);
