-- Ensures existing and newly authenticated readers always have their app records.
create or replace function public.ensure_reader()
returns void language plpgsql security definer set search_path = public as $$
declare u uuid:=auth.uid();
begin
 if u is null then raise exception 'Authentication required'; end if;
 insert into profiles(id,display_name) values(u,coalesce(auth.jwt()->'user_metadata'->>'display_name',split_part(coalesce(auth.jwt()->>'email','Reader'),'@',1))) on conflict(id) do nothing;
 insert into user_agendas(user_id) values(u) on conflict(user_id) do nothing;
end $$;
grant execute on function public.ensure_reader() to authenticated;

-- Saves a swipe and atomically adjusts the signed-in reader's agenda.
create or replace function public.record_swipe(p_article_id bigint, p_direction public.swipe_direction)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid:=auth.uid(); old public.swipe_direction; cat text; scores jsonb; delta int; value int; pref text[]; blocked text[];
begin
 if u is null then raise exception 'Authentication required'; end if;
 select category into cat from articles where id=p_article_id and status='published'; if cat is null then raise exception 'Published article not found'; end if;
 insert into user_agendas(user_id) values(u) on conflict(user_id) do nothing;
 select direction into old from swipes where user_id=u and article_id=p_article_id;
 insert into swipes(user_id,article_id,direction) values(u,p_article_id,p_direction) on conflict(user_id,article_id) do update set direction=excluded.direction,created_at=now();
 select preference_scores into scores from user_agendas where user_id=u for update;
 delta:=(case p_direction when 'right' then 1 else -1 end)-(case old when 'right' then 1 when 'left' then -1 else 0 end);
 value:=coalesce((scores->>cat)::int,0)+delta; scores:=jsonb_set(coalesce(scores,'{}'::jsonb),array[cat],to_jsonb(value),true);
 select coalesce(array_agg(key order by key) filter(where val::int>0),'{}'),coalesce(array_agg(key order by key) filter(where val::int<=-3),'{}') into pref,blocked from jsonb_each_text(scores) x(key,val);
 update user_agendas set preference_scores=scores,preferred_categories=pref,blocked_categories=blocked,updated_at=now() where user_id=u;
 return (select jsonb_build_object('preference_scores',preference_scores,'preferred_categories',preferred_categories,'blocked_categories',blocked_categories) from user_agendas where user_id=u);
end $$;
grant execute on function public.record_swipe(bigint,public.swipe_direction) to authenticated;
