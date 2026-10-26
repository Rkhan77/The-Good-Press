-- Route Supabase authentication mail through the protected delivery queue.
-- worker. This avoids password-based SMTP and keeps auth tokens server-side.

alter table public.notification_outbox
  drop constraint if exists notification_outbox_kind_check;

alter table public.notification_outbox
  add constraint notification_outbox_kind_check
  check (kind in ('auth', 'welcome', 'new_articles', 'card_reset'));

create or replace function public.send_auth_email_hook(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reader_id uuid := (event->'user'->>'id')::uuid;
  current_email text := event->'user'->>'email';
  new_email text := event->'user'->>'new_email';
  action_type text := event->'email_data'->>'email_action_type';
  redirect_target text := event->'email_data'->>'redirect_to';
  token_value text := event->'email_data'->>'token';
  token_hash_value text := event->'email_data'->>'token_hash';
  token_new_value text := event->'email_data'->>'token_new';
  token_hash_new_value text := event->'email_data'->>'token_hash_new';
begin
  if reader_id is null or action_type is null then
    raise exception 'Invalid authentication email event';
  end if;

  if action_type = 'email_change' and nullif(token_hash_new_value, '') is not null then
    insert into public.notification_outbox (kind, user_id, payload, idempotency_key)
    values (
      'auth',
      reader_id,
      jsonb_build_object('recipient', current_email, 'action', action_type, 'token', token_value, 'token_hash', token_hash_new_value, 'redirect_to', redirect_target),
      'auth:' || reader_id::text || ':' || md5(action_type || ':' || coalesce(current_email, '') || ':' || token_hash_new_value)
    )
    on conflict (idempotency_key) do nothing;

    insert into public.notification_outbox (kind, user_id, payload, idempotency_key)
    values (
      'auth',
      reader_id,
      jsonb_build_object('recipient', new_email, 'action', action_type, 'token', token_new_value, 'token_hash', token_hash_value, 'redirect_to', redirect_target),
      'auth:' || reader_id::text || ':' || md5(action_type || ':' || coalesce(new_email, '') || ':' || coalesce(token_hash_value, ''))
    )
    on conflict (idempotency_key) do nothing;
  else
    insert into public.notification_outbox (kind, user_id, payload, idempotency_key)
    values (
      'auth',
      reader_id,
      jsonb_build_object(
        'recipient', case when action_type = 'email_change' then coalesce(nullif(new_email, ''), current_email) else current_email end,
        'action', action_type,
        'token', coalesce(nullif(token_new_value, ''), token_value),
        'token_hash', coalesce(nullif(token_hash_value, ''), token_hash_new_value),
        'redirect_to', redirect_target
      ),
      'auth:' || reader_id::text || ':' || md5(action_type || ':' || coalesce(case when action_type = 'email_change' then new_email else current_email end, '') || ':' || coalesce(token_hash_value, token_hash_new_value, ''))
    )
    on conflict (idempotency_key) do nothing;
  end if;

  return '{}'::jsonb;
end;
$$;

revoke all on function public.send_auth_email_hook(jsonb) from public, anon, authenticated;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.send_auth_email_hook(jsonb) to supabase_auth_admin;

-- Authentication links should normally leave the queue within one minute.
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
  '* * * * *',
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
