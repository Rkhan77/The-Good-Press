-- Subscription entitlements are written only by the payment webhook.
-- Browser clients can read their own entitlement but cannot grant themselves access.
create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  provider text not null default 'stripe' check (provider in ('stripe')),
  provider_customer_id text unique,
  provider_subscription_id text unique,
  status text not null default 'inactive' check (status in ('inactive', 'pending', 'trialing', 'active', 'past_due', 'unpaid', 'canceled', 'incomplete', 'incomplete_expired')),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists subscriptions_status_idx
  on public.subscriptions (status, current_period_end);

alter table public.subscriptions enable row level security;

create policy "Users can read their own subscription"
on public.subscriptions for select
to authenticated
using ((select auth.uid()) = user_id);

grant select on public.subscriptions to authenticated;

-- The signed-in app uses this RPC; direct writes would let a reader bypass the free limit.
revoke insert, update, delete on public.swipes from authenticated;

create or replace function public.record_swipe(p_article_id bigint, p_direction public.swipe_direction)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid:=auth.uid(); old public.swipe_direction; cat text; scores jsonb; delta int; value int; pref text[]; blocked text[]; unlimited boolean; used_cards int;
begin
 if u is null then raise exception 'Authentication required'; end if;
 select category into cat from articles where id=p_article_id and status='published';
 if cat is null then raise exception 'Published article not found'; end if;
 insert into user_agendas(user_id) values(u) on conflict(user_id) do nothing;
 select direction into old from swipes where user_id=u and article_id=p_article_id;
 select exists(
   select 1 from subscriptions
   where user_id=u
     and status in ('active','trialing')
     and (current_period_end is null or current_period_end > now())
 ) into unlimited;
 if old is null and not unlimited then
   select count(*) into used_cards from swipes
   where user_id=u and created_at >= date_trunc('month', now());
   if used_cards >= 25 then raise exception 'Free monthly card limit reached'; end if;
 end if;
 insert into swipes(user_id,article_id,direction) values(u,p_article_id,p_direction)
 on conflict(user_id,article_id) do update set direction=excluded.direction;
 select preference_scores into scores from user_agendas where user_id=u for update;
 delta:=(case p_direction when 'right' then 1 else -1 end)-(case old when 'right' then 1 when 'left' then -1 else 0 end);
 value:=coalesce((scores->>cat)::int,0)+delta;
 scores:=jsonb_set(coalesce(scores,'{}'::jsonb),array[cat],to_jsonb(value),true);
 select coalesce(array_agg(key order by key) filter(where val::int>=10),'{}'),coalesce(array_agg(key order by key) filter(where val::int<=-3),'{}') into pref,blocked from jsonb_each_text(scores) x(key,val);
 update user_agendas set preference_scores=scores,preferred_categories=pref,blocked_categories=blocked,updated_at=now() where user_id=u;
 return (select jsonb_build_object('preference_scores',preference_scores,'preferred_categories',preferred_categories,'blocked_categories',blocked_categories) from user_agendas where user_id=u);
end $$;

grant execute on function public.record_swipe(bigint,public.swipe_direction) to authenticated;
