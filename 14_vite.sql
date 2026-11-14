-- CASTING : Avis et bugs + Coffret offert par les missions de la semaine (comme Kyara).
-- A coller en entier dans Supabase > SQL Editor > New query > Run APRES 13_gros_tirages.sql.
-- Peut etre lance plusieurs fois sans risque.

-- ---------- Avis et bugs ----------
create table if not exists feedback(
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null check (kind in ('idee','bug','carte','autre')),
  body text not null check (length(body) between 3 and 2000),
  reply text,
  at timestamptz not null default now());
alter table feedback enable row level security;
-- aucune politique : on passe seulement par les fonctions ci-dessous. Les messages se lisent dans Supabase > Table editor > feedback
-- (colonne reply pour repondre : la reponse s'affiche sous le message dans le jeu).

create or replace function send_feedback(kind text, body text) returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Connecte-toi'; end if;
  if (select count(*) from feedback where user_id=auth.uid() and at > now() - interval '1 hour') >= 10 then
    raise exception 'Trop de messages d''un coup, reessaie dans un moment'; end if;
  insert into feedback(user_id,kind,body) values(auth.uid(), send_feedback.kind, trim(send_feedback.body));
end $$;

create or replace function my_feedback() returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'body',body,'reply',reply,'at',at) order by at desc),'[]'::jsonb)
  from (select * from feedback where user_id=auth.uid() order by at desc limit 50) f;
$$;

-- ---------- Coffret offert ----------
alter table profiles add column if not exists free_coffret int not null default 0;

-- recuperer une recompense (remplace celle de 9_lot1_boosters_missions.sql) :
-- les 3 missions de la semaine donnent maintenant un Coffret offert (comme Kyara) au lieu de 3 boosters.
create or replace function claim_quest(qid text) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); d jsonb; k text; got int := 0; boosts int := 0; dn int; p profiles;
        rw int[] := array[20,30,40,50,60,80,100];
begin
  if uid is null then raise exception 'Connecte-toi'; end if;
  select * into p from profiles where id=uid for update;
  if p.id is null then raise exception 'Connecte-toi'; end if;

  if qid='streak' then
    if p.streak_last = today_fr() then raise exception 'Déjà récupéré aujourd''hui'; end if;
    dn := case when p.streak_last is not null and p.streak_last >= today_fr()-2 and p.streak_day < 7 then p.streak_day+1 else 1 end;
    got := rw[dn];
    update profiles set streak_day=dn, streak_last=today_fr(), popcorns=popcorns+got,
      golden_in = case when dn=7 then 0 else golden_in end where id=uid;
    return jsonb_build_object('popcorns',got,'golden',dn=7,'state',my_state());
  end if;

  if qid in ('bonus_welcome','bonus_daily','bonus_weekly') then
    k := substr(qid,7);
    if exists(select 1 from jsonb_array_elements(quest_defs()) x where x->>'kind'=k and q_val(uid,k,x->>'ev') < (x->>'target')::int) then
      raise exception 'Termine d''abord toutes les missions'; end if;
    insert into quest_claims(user_id,scope,qid) values(uid,q_scope(k),'bonus') on conflict do nothing;
    if not found then raise exception 'Déjà récupéré'; end if;
    if k='weekly' then
      update profiles set free_coffret=free_coffret+1 where id=uid;
      return jsonb_build_object('coffret',1,'state',my_state());
    end if;
    boosts := case k when 'daily' then 1 else 3 end;
    update profiles set bonus_stock=bonus_stock+boosts where id=uid;
    return jsonb_build_object('boosters',boosts,'state',my_state());
  end if;

  select x into d from jsonb_array_elements(quest_defs()) x where x->>'id'=claim_quest.qid;
  if d is null then raise exception 'Mission inconnue'; end if;
  if q_val(uid,d->>'kind',d->>'ev') < (d->>'target')::int then raise exception 'Mission pas encore terminée'; end if;
  insert into quest_claims(user_id,scope,qid) values(uid,q_scope(d->>'kind'),claim_quest.qid) on conflict do nothing;
  if not found then raise exception 'Déjà récupéré'; end if;
  got := (d->>'pop')::int;
  update profiles set popcorns=popcorns+got where id=uid;
  return jsonb_build_object('popcorns',got,'state',my_state());
end $$;

create or replace function my_free_coffret() returns int language sql stable security definer set search_path=public as $$
  select coalesce((select free_coffret from profiles where id=auth.uid()),0);
$$;

-- ouvre un Coffret offert : on rend le prix en Popcorns puis on ouvre un Coffret normal (meme tirage, memes compteurs).
-- Si l'ouverture echoue, tout est annule (meme transaction).
create or replace function open_free_coffret() returns jsonb language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'Connecte-toi'; end if;
  select free_coffret into n from profiles where id=auth.uid() for update;
  if coalesce(n,0) < 1 then raise exception 'Pas de Coffret offert'; end if;
  update profiles set free_coffret=free_coffret-1, popcorns=popcorns+cfg('shop_coffret') where id=auth.uid();
  return open_boosters('shop','coffret',1);
end $$;

revoke all on function send_feedback(text,text), my_feedback(), claim_quest(text), my_free_coffret(), open_free_coffret() from public;
grant execute on function send_feedback(text,text), my_feedback(), claim_quest(text), my_free_coffret(), open_free_coffret() to authenticated;
