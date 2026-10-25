-- Queue one service welcome email for every newly created reader account.

alter table public.notification_outbox
  drop constraint if exists notification_outbox_kind_check;

alter table public.notification_outbox
  add constraint notification_outbox_kind_check
  check (kind in ('welcome', 'new_articles', 'card_reset'));

create or replace function public.queue_welcome_email_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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
    '{}'::jsonb,
    now(),
    'welcome:' || new.id::text
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_welcome_email on auth.users;
create trigger on_auth_user_created_welcome_email
after insert on auth.users
for each row execute function public.queue_welcome_email_for_new_user();
