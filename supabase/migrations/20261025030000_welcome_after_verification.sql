-- Welcome readers only after authentication is complete.
-- Email/password readers are queued when they confirm their address.
-- OAuth readers arrive already confirmed, so they are queued on insert.

drop trigger if exists on_auth_user_created_welcome_email on auth.users;

create or replace function public.queue_welcome_email_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is null or new.email_confirmed_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.email_confirmed_at is not null then
    return new;
  end if;

  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  insert into public.notification_outbox (
    kind,
    user_id,
    payload,
    scheduled_for,
    idempotency_key
  )
  values (
    'welcome',
    new.id,
    jsonb_build_object('provider', coalesce(new.raw_app_meta_data->>'provider', 'email')),
    now(),
    'welcome-confirmed:' || new.id::text
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

-- Remove only premature, unsent welcome jobs created for unverified readers.
-- Their confirmation event will create a new welcome-confirmed job later.
delete from public.notification_outbox outbox
using auth.users reader
where outbox.user_id = reader.id
  and outbox.kind = 'welcome'
  and outbox.status = 'pending'
  and reader.email_confirmed_at is null;

drop trigger if exists verified_reader_welcome_on_insert on auth.users;
create trigger verified_reader_welcome_on_insert
after insert on auth.users
for each row execute function public.queue_welcome_email_for_new_user();

drop trigger if exists verified_reader_welcome_on_confirmation on auth.users;
create trigger verified_reader_welcome_on_confirmation
after update of email_confirmed_at on auth.users
for each row execute function public.queue_welcome_email_for_new_user();
