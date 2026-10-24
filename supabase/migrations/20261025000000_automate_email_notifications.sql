-- Automatically collect newly published articles into short email digests and
-- invoke the notification worker every five minutes. The scheduler secret is
-- generated inside Supabase Vault and never stored in source control.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

do $$
begin
  if not exists (
    select 1 from vault.secrets where name = 'good_press_notification_worker'
  ) then
    perform vault.create_secret(
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
      'good_press_notification_worker',
      'Authenticates the internal five-minute notification worker schedule'
    );
  end if;
end;
$$;

create or replace function public.authorize_notification_worker(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, vault
as $$
  select exists (
    select 1
    from vault.decrypted_secrets
    where name = 'good_press_notification_worker'
      and decrypted_secret = p_secret
  );
$$;

revoke all on function public.authorize_notification_worker(text) from public, anon, authenticated;
grant execute on function public.authorize_notification_worker(text) to service_role;

create or replace function public.queue_new_published_article()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  digest_bucket text := floor(extract(epoch from now()) / 600)::bigint::text;
begin
  if new.status::text <> 'published' then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status::text = 'published' then
    return new;
  end if;

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
    jsonb_build_object('article_ids', jsonb_build_array(new.id)),
    now() + interval '10 minutes',
    'new_articles:auto:' || preference.user_id::text || ':' || digest_bucket
  from public.notification_preferences preference
  where preference.new_articles
    and preference.consented_at is not null
    and preference.unsubscribed_at is null
  on conflict (idempotency_key) do update
  set payload = jsonb_build_object(
        'article_ids',
        (
          select jsonb_agg(article_id order by article_id)
          from (
            select distinct value::bigint as article_id
            from jsonb_array_elements_text(
              public.notification_outbox.payload->'article_ids' || excluded.payload->'article_ids'
            ) as combined(value)
          ) as unique_ids
        )
      ),
      scheduled_for = least(public.notification_outbox.scheduled_for, excluded.scheduled_for);

  return new;
end;
$$;

drop trigger if exists articles_queue_email_notification on public.articles;
create trigger articles_queue_email_notification
after insert or update of status on public.articles
for each row execute function public.queue_new_published_article();

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'good-press-notification-worker'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end;
$$;

select cron.schedule(
  'good-press-notification-worker',
  '*/5 * * * *',
  $schedule$
    select net.http_post(
      url := 'https://ltdzjanqhxrleqbtkpoo.supabase.co/functions/v1/notification-worker',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Worker-Secret', (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'good_press_notification_worker'
          limit 1
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    ) as request_id;
  $schedule$
);
