-- Saved news is available to every signed-in reader, regardless of subscription.
drop policy if exists "Subscribers can read their own saved articles" on public.saved_articles;
drop policy if exists "Subscribers can save their own articles" on public.saved_articles;
drop policy if exists "Subscribers can remove their own saved articles" on public.saved_articles;

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
