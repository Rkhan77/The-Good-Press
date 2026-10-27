-- Remember notification prompt dismissals across sessions and devices.
-- Readers with an enabled option never see the prompt. Readers who keep every
-- option off are asked again on every third subsequent authenticated login.

alter table public.notification_preferences
  add column if not exists prompt_login_count integer not null default 0,
  add column if not exists prompt_next_login integer not null default 0;

alter table public.notification_preferences
  drop constraint if exists notification_preferences_prompt_login_count_check,
  drop constraint if exists notification_preferences_prompt_next_login_check;

alter table public.notification_preferences
  add constraint notification_preferences_prompt_login_count_check
    check (prompt_login_count >= 0),
  add constraint notification_preferences_prompt_next_login_check
    check (prompt_next_login >= 0);

create or replace function public.register_notification_login()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reader_id uuid := auth.uid();
  preference public.notification_preferences;
begin
  if reader_id is null then
    raise exception 'Authentication required';
  end if;

  insert into public.notification_preferences (user_id)
  values (reader_id)
  on conflict (user_id) do nothing;

  update public.notification_preferences
  set prompt_login_count = prompt_login_count + 1
  where user_id = reader_id
  returning * into preference;

  return jsonb_build_object(
    'new_articles', preference.new_articles,
    'card_reset', preference.card_reset,
    'unread_reminders', preference.unread_reminders,
    'consented_at', preference.consented_at,
    'unsubscribed_at', preference.unsubscribed_at,
    'prompt_login_count', preference.prompt_login_count,
    'prompt_next_login', preference.prompt_next_login
  );
end;
$$;

create or replace function public.defer_notification_prompt(p_login_delay integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reader_id uuid := auth.uid();
  preference public.notification_preferences;
  login_delay integer := greatest(1, least(coalesce(p_login_delay, 3), 30));
begin
  if reader_id is null then
    raise exception 'Authentication required';
  end if;

  update public.notification_preferences
  set prompt_next_login = prompt_login_count + login_delay
  where user_id = reader_id
  returning * into preference;

  if preference.user_id is null then
    raise exception 'Notification preferences not found';
  end if;

  return jsonb_build_object(
    'new_articles', preference.new_articles,
    'card_reset', preference.card_reset,
    'unread_reminders', preference.unread_reminders,
    'consented_at', preference.consented_at,
    'unsubscribed_at', preference.unsubscribed_at,
    'prompt_login_count', preference.prompt_login_count,
    'prompt_next_login', preference.prompt_next_login
  );
end;
$$;

revoke all on function public.register_notification_login() from public, anon;
revoke all on function public.defer_notification_prompt(integer) from public, anon;
grant execute on function public.register_notification_login() to authenticated;
grant execute on function public.defer_notification_prompt(integer) to authenticated;
