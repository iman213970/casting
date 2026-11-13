-- CASTING lot 1 : slots a rarete minimale (C C C U R), booster dore tous les 10, god pack, missions,
-- serie de connexion sur 7 jours et succes.
-- A coller en entier dans Supabase > SQL Editor > New query > Run APRES 6_etape1_suite.sql.
-- Peut etre lance plusieurs fois sans risque. Les journees et semaines suivent l'heure de Paris.

-- ---------- reglages ----------
-- golden_every : un booster dore apres 10 boosters normaux
-- god_chance : chance d'un booster E E E E M, sur 100 000 (50 = 0,05 %)
insert into config(k,v) values ('golden_every',10),('god_chance',50)
  on conflict(k) do update set v=excluded.v;

alter table profiles add column if not exists golden_in int not null default 10;
alter table profiles add column if not exists streak_day int not null default 0;
alter table profiles add column if not exists streak_last date;

create or replace function today_fr() returns date language sql stable as $$
  select (now() at time zone 'Europe/Paris')::date $$;

-- ---------- tirage par slot ----------
-- Une carte au hasard d'une rarete donnee, dans un genre (ou tout le catalogue si genre est null)
create or replace function pick_card_r(rar text, genre text) returns int language sql volatile set search_path=public as $$
  select n from cards where r=rar and (genre is null or genre=any(g)) order by random() limit 1 $$;

-- Rarete tiree avec les poids p_C..p_M, en retirant celles sous le plancher du slot
create or replace function pick_rarity_min(minr text) returns text language plpgsql volatile set search_path=public as $$
declare allowed text := substr('CURELM', position(minr in 'CURELM')); ch text; tot int := 0; x int; acc int := 0;
begin
  foreach ch in array string_to_array(allowed,null) loop tot := tot + cfg('p_'||ch); end loop;
  x := 1 + floor(random()*tot)::int;
  foreach ch in array string_to_array(allowed,null) loop
    acc := acc + cfg('p_'||ch); if x <= acc then return ch; end if;
  end loop;
  return minr;
end $$;

-- Une carte pour un slot : si le genre n'a pas cette rarete, on descend jusqu'au plancher puis on remonte
create or replace function pick_slot(minr text, genre text) returns int language plpgsql volatile set search_path=public as $$
declare rar text := pick_rarity_min(minr); c int; i int;
begin
  c := pick_card_r(rar, genre); if c is not null then return c; end if;
  for i in reverse position(rar in 'CURELM')-1 .. position(minr in 'CURELM') loop
    c := pick_card_r(substr('CURELM',i,1), genre); if c is not null then return c; end if;
  end loop;
  for i in position(rar in 'CURELM')+1 .. 6 loop
    c := pick_card_r(substr('CURELM',i,1), genre); if c is not null then return c; end if;
  end loop;
  return (select n from cards where genre is null or genre=any(g) order by random() limit 1);
end $$;

-- ---------- missions : definitions ----------
-- kind : welcome (une fois), daily (chaque jour), weekly (chaque lundi), ach (succes, une fois)
-- ev : open (boosters ouverts), pull_E / pull_L / pull_M (cartes Epique ou mieux / Legendaires / Mythiques obtenues),
--      new (nouvelles cartes), recycle (cartes recyclees), view (fiche ouverte),
--      unique (cartes differentes possedees), m_unique (Mythiques differentes possedees)
create or replace function quest_defs() returns jsonb language sql immutable as $$ select $j$[
 {"id":"w1","kind":"welcome","label":"Ouvre ton premier booster","ev":"open","target":1,"pop":20},
 {"id":"w2","kind":"welcome","label":"Recycle un doublon","ev":"recycle","target":1,"pop":20},
 {"id":"w3","kind":"welcome","label":"Ouvre la fiche d'une carte","ev":"view","target":1,"pop":20},
 {"id":"w4","kind":"welcome","label":"Obtiens une carte Épique ou mieux","ev":"pull_E","target":1,"pop":30},
 {"id":"w5","kind":"welcome","label":"Ouvre 10 boosters","ev":"open","target":10,"pop":50},
 {"id":"d1","kind":"daily","label":"Obtiens une carte Épique ou mieux","ev":"pull_E","target":1,"pop":30},
 {"id":"d2","kind":"daily","label":"Recycle 5 doublons","ev":"recycle","target":5,"pop":20},
 {"id":"d3","kind":"daily","label":"Ouvre 15 boosters","ev":"open","target":15,"pop":40},
 {"id":"h1","kind":"weekly","label":"Obtiens une Mythique","ev":"pull_M","target":1,"pop":250},
 {"id":"h2","kind":"weekly","label":"Obtiens une Légendaire","ev":"pull_L","target":1,"pop":150},
 {"id":"h3","kind":"weekly","label":"Ouvre 75 boosters","ev":"open","target":75,"pop":200},
 {"id":"a1","kind":"ach","label":"Premiers pas","desc":"Ouvre 10 boosters","ev":"open","target":10,"pop":10},
 {"id":"a2","kind":"ach","label":"Habitué","desc":"Ouvre 100 boosters","ev":"open","target":100,"pop":50},
 {"id":"a3","kind":"ach","label":"Accro","desc":"Ouvre 1 000 boosters","ev":"open","target":1000,"pop":300},
 {"id":"a4","kind":"ach","label":"Binge-watcher","desc":"Ouvre 10 000 boosters","ev":"open","target":10000,"pop":2000},
 {"id":"a5","kind":"ach","label":"Collectionneur","desc":"Possède 50 cartes différentes","ev":"unique","target":50,"pop":20},
 {"id":"a6","kind":"ach","label":"Archiviste","desc":"Possède 250 cartes différentes","ev":"unique","target":250,"pop":75},
 {"id":"a7","kind":"ach","label":"Encyclopédiste","desc":"Possède 1 000 cartes différentes","ev":"unique","target":1000,"pop":300},
 {"id":"a8","kind":"ach","label":"Bibliothécaire","desc":"Possède 2 500 cartes différentes","ev":"unique","target":2500,"pop":800},
 {"id":"a9","kind":"ach","label":"Épique !","desc":"Obtiens ta première Épique","ev":"pull_E","target":1,"pop":20},
 {"id":"a10","kind":"ach","label":"Légendaire !","desc":"Obtiens ta première Légendaire","ev":"pull_L","target":1,"pop":75},
 {"id":"a11","kind":"ach","label":"Mythique !","desc":"Obtiens ta première Mythique","ev":"pull_M","target":1,"pop":200},
 {"id":"a12","kind":"ach","label":"Panthéon","desc":"Possède 10 Mythiques différentes","ev":"m_unique","target":10,"pop":500},
 {"id":"a13","kind":"ach","label":"Chasseur de légendes","desc":"Obtiens 100 Légendaires","ev":"pull_L","target":100,"pop":400},
 {"id":"a14","kind":"ach","label":"Grand ménage","desc":"Recycle 1 000 cartes","ev":"recycle","target":1000,"pop":100},
 {"id":"a15","kind":"ach","label":"Broyeur","desc":"Recycle 10 000 cartes","ev":"recycle","target":10000,"pop":500}
]$j$::jsonb $$;

-- ---------- missions : compteurs ----------
create table if not exists quest_counts(
  user_id uuid not null references profiles(id) on delete cascade,
  scope text not null, ev text not null, val int not null default 0,
  primary key(user_id,scope,ev));
create table if not exists quest_claims(
  user_id uuid not null references profiles(id) on delete cascade,
  scope text not null, qid text not null, at timestamptz not null default now(),
  primary key(user_id,scope,qid));
-- lecture et ecriture uniquement par les fonctions ci-dessous
alter table quest_counts enable row level security;
alter table quest_claims enable row level security;

-- periode d'une mission : d2026-11-13 pour le jour, w2026-46 pour la semaine, a pour le reste
create or replace function q_scope(kind text) returns text language sql stable as $$
  select case kind when 'daily' then 'd'||to_char(today_fr(),'YYYY-MM-DD')
                   when 'weekly' then 'w'||to_char(today_fr(),'IYYY-IW') else 'a' end $$;

create or replace function q_bump(uid uuid, e text, k int) returns void language plpgsql security definer set search_path=public as $$
declare s text;
begin
  if uid is null or k is null or k <= 0 then return; end if;
  foreach s in array array[q_scope('daily'), q_scope('weekly'), 'a'] loop
    insert into quest_counts(user_id,scope,ev,val) values(uid,s,e,k)
      on conflict(user_id,scope,ev) do update set val=quest_counts.val+k;
  end loop;
end $$;

create or replace function q_val(uid uuid, kind text, e text) returns int language plpgsql stable security definer set search_path=public as $$
begin
  if e='unique' then return (select count(*) from inv where user_id=uid and qty>0); end if;
  if e='m_unique' then return (select count(*) from inv i join cards c on c.n=i.n where i.user_id=uid and i.qty>0 and c.r='M'); end if;
  return coalesce((select val from quest_counts where user_id=uid and scope=q_scope(kind) and ev=e),0);
end $$;

-- recyclage (et toute baisse de quantite) compte pour les missions, sans toucher a la fonction recycle existante
create or replace function inv_track() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.qty < old.qty then perform q_bump(new.user_id,'recycle',old.qty-new.qty); end if;
  return null;
end $$;
drop trigger if exists inv_track on inv;
create trigger inv_track after update on inv for each row execute function inv_track();

-- ---------- missions : etat complet pour la page Missions ----------
create or replace function my_quests_for(uid uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare d jsonb; res jsonb := '[]'::jsonb; v int; t int; cl bool; claimable int := 0; k text;
        bon jsonb := '{}'::jsonb; alld bool; bc bool; p profiles; sd int; sok bool; nxt int;
begin
  for d in select x from jsonb_array_elements(quest_defs()) x loop
    v := q_val(uid, d->>'kind', d->>'ev'); t := (d->>'target')::int;
    cl := exists(select 1 from quest_claims c where c.user_id=uid and c.scope=q_scope(d->>'kind') and c.qid=d->>'id');
    if v >= t and not cl then claimable := claimable + 1; end if;
    res := res || jsonb_build_array(d || jsonb_build_object('progress',least(v,t),'done',v>=t,'claimed',cl));
  end loop;
  foreach k in array array['welcome','daily','weekly'] loop
    alld := not exists(select 1 from jsonb_array_elements(res) x where x->>'kind'=k and not (x->>'done')::bool);
    bc := exists(select 1 from quest_claims c where c.user_id=uid and c.scope=q_scope(k) and c.qid='bonus');
    bon := bon || jsonb_build_object(k, jsonb_build_object('all',alld,'claimed',bc));
    if alld and not bc then claimable := claimable + 1; end if;
  end loop;
  select * into p from profiles where id=uid;
  sok := p.streak_last is distinct from today_fr();
  -- un jour de grace : la serie tient si le dernier jour recupere date d'hier ou d'avant-hier
  sd := case when p.streak_last >= today_fr()-2 then p.streak_day else 0 end;
  nxt := case when not sok then null when p.streak_last is null or p.streak_last < today_fr()-2 or sd >= 7 then 1 else sd+1 end;
  if sok then claimable := claimable + 1; end if;
  return jsonb_build_object('quests',res,'bonus',bon,'claimable',claimable,
    'bonus_rewards',jsonb_build_object('welcome',3,'daily',1,'weekly',3),
    'streak',jsonb_build_object('day',sd,'claimed_today',not sok,'next',nxt,'rewards',to_jsonb(array[20,30,40,50,60,80,100])),
    'next_daily',extract(epoch from ((today_fr()+1)::timestamp at time zone 'Europe/Paris' - now()))::int,
    'next_weekly',extract(epoch from (((date_trunc('week',today_fr()::timestamp))::date+7)::timestamp at time zone 'Europe/Paris' - now()))::int);
end $$;

create or replace function my_quests() returns jsonb language sql security definer set search_path=public as $$
  select my_quests_for(auth.uid()) $$;

-- evenement envoye par le site : seulement « fiche ouverte »
create or replace function quest_event(e text) returns void language plpgsql security definer set search_path=public as $$
begin
  if e <> 'view' then raise exception 'Événement inconnu'; end if;
  perform q_bump(auth.uid(),'view',1);
end $$;

-- ---------- etat du joueur (remplace celui de 6_etape1_suite.sql) ----------
drop function if exists my_state();
create or replace function my_state() returns jsonb language plpgsql security definer set search_path=public as $$
declare p profiles; step interval := make_interval(mins=>cfg('free_minutes')); nxt int; q jsonb;
begin
  perform refill(auth.uid());
  select * into p from profiles where id=auth.uid();
  if p.id is null then return null; end if;
  nxt := case when p.free_stock >= cfg('free_max') then null else greatest(0, ceil(extract(epoch from (p.free_at + step - now()))))::int end;
  q := my_quests_for(p.id);
  return jsonb_build_object('name',p.name,'popcorns',p.popcorns,'boosters',p.boosters,'pity',p.since_mythic,
    'pity_max',cfg('pity'),'free',p.free_stock,'bonus',p.bonus_stock,'free_max',cfg('free_max'),'free_next',nxt,
    'daily_ready', coalesce(p.last_daily,'1970-01-01') < today_fr(),'daily_theme',daily_theme(),'themes',to_jsonb(themes()),
    'price',cfg('price'),'gprice',cfg('gprice'),'bonus_L',cfg('bonus_L'),'bonus_M',cfg('bonus_M'),
    'golden_in',p.golden_in,'golden_every',cfg('golden_every'),
    'quests',jsonb_build_object('claimable',q->'claimable',
       'daily_done',(select count(*) from jsonb_array_elements(q->'quests') x where x->>'kind'='daily' and (x->>'done')::bool),
       'daily_total',(select count(*) from jsonb_array_elements(q->'quests') x where x->>'kind'='daily'),
       'streak_day',q->'streak'->'day','streak_ready',not (q->'streak'->>'claimed_today')::bool),
    'odds',jsonb_build_object('M',cfg('p_M'),'L',cfg('p_L'),'E',cfg('p_E'),'R',cfg('p_R'),'U',cfg('p_U'),'C',cfg('p_C')),
    'inv', coalesce((select jsonb_object_agg(n::text,qty) from inv where user_id=p.id),'{}'::jsonb));
end $$;

-- ---------- recuperer une recompense ----------
-- qid : id d'une mission, 'streak' (serie de connexion), ou bonus_welcome / bonus_daily / bonus_weekly
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
    -- jour 7 : le prochain booster devient dore
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

-- ---------- ouverture (remplace celle de 6_etape1_suite.sql) ----------
-- Slots : normal C C C U R, pack du jour et booster dore C C U R E, god pack E E E E M.
create or replace function open_boosters(kind text, genre text default null, qty int default 1) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p profiles; picks int[]; c int; b int; i int; slots text; pity_hit bool; has bool; was_owned bool; seen int[] := '{}';
        price int; sm int; gi int; golden bool; god bool; use_free int; cres jsonb; all_b jsonb := '[]'::jsonb;
        gain int := 0; bonus int; cr text; n_e int := 0; n_l int := 0; n_m int := 0; n_new int := 0;
begin
  if qty not in (1,5,10) then raise exception 'Quantité invalide'; end if;
  perform refill(auth.uid());
  select * into p from profiles where id=auth.uid() for update;
  if p.id is null then raise exception 'Connecte-toi'; end if;
  if genre is not null and not (genre = any(themes())) then raise exception 'Thème inconnu'; end if;
  if kind='daily' then
    if qty<>1 then raise exception 'Un seul pack du jour'; end if;
    if p.last_daily >= today_fr() then raise exception 'Pack du jour déjà ouvert'; end if;
    update profiles set last_daily=today_fr() where id=p.id; genre := daily_theme();
  elsif kind='free' then
    if p.free_stock + p.bonus_stock < qty then raise exception 'Pas assez de boosters gratuits'; end if;
    use_free := least(p.free_stock, qty);
    update profiles set free_stock=free_stock-use_free, bonus_stock=bonus_stock-(qty-use_free),
      free_at = case when free_stock>=cfg('free_max') then now() else free_at end where id=p.id;
  elsif kind='paid' then
    price := (case when genre is null then cfg('price') else cfg('gprice') end) * qty;
    if p.popcorns < price then raise exception 'Pas assez de Popcorns'; end if;
    update profiles set popcorns=popcorns-price where id=p.id;
  else raise exception 'Type de booster inconnu'; end if;

  sm := p.since_mythic; gi := p.golden_in;
  for b in 1..qty loop
    golden := false; god := false;
    if kind='daily' then slots := 'CCURE';
    elsif random()*100000 < cfg('god_chance') then god := true; slots := 'EEEEM';
    elsif gi <= 0 then golden := true; slots := 'CCURE';
    else slots := 'CCCUR'; end if;
    if kind <> 'daily' then gi := case when golden then cfg('golden_every') else greatest(gi-1,0) end; end if;

    picks := '{}'; pity_hit := sm+1 >= cfg('pity');
    for i in 1..length(slots) loop picks := picks || pick_slot(substr(slots,i,1), genre); end loop;
    if pity_hit and not exists(select 1 from cards where n=any(picks) and r='M') then
      c := coalesce(pick_card_r('M',genre), pick_card_r('M',null)); if c is not null then picks[length(slots)] := c; end if;
    end if;
    has := exists(select 1 from cards where n=any(picks) and r='M');

    cres := '[]'::jsonb;
    foreach c in array picks loop
      was_owned := exists(select 1 from inv where user_id=p.id and n=c) or c=any(seen);
      seen := seen || c;
      insert into inv(user_id,n,qty) values(p.id,c,1) on conflict(user_id,n) do update set qty=inv.qty+1;
      select r into cr from cards where n=c;
      if cr in ('E','L','M') then n_e := n_e+1; end if;
      if cr='L' then n_l := n_l+1; end if;
      if cr='M' then n_m := n_m+1; end if;
      if not was_owned then n_new := n_new+1; end if;
      bonus := case when cr='L' then cfg('bonus_L') when cr='M' then cfg('bonus_M') else 0 end;
      gain := gain + bonus;
      cres := cres || jsonb_build_object('n',c,'new',not was_owned,'bonus',bonus);
    end loop;
    sm := case when has then 0 else sm+1 end;
    all_b := all_b || jsonb_build_object('cards',cres,'pity_hit',pity_hit and has,'golden',golden,'god',god);
  end loop;
  update profiles set boosters=boosters+qty, since_mythic=sm, golden_in=gi, popcorns=popcorns+gain where id=p.id;
  perform q_bump(p.id,'open',qty); perform q_bump(p.id,'pull_E',n_e); perform q_bump(p.id,'pull_L',n_l);
  perform q_bump(p.id,'pull_M',n_m); perform q_bump(p.id,'new',n_new);
  return jsonb_build_object('boosters',all_b,'gain',gain,'state',my_state());
end $$;

-- ---------- droits ----------
revoke all on function open_boosters(text,text,int), my_state(), my_quests(), claim_quest(text), quest_event(text),
  my_quests_for(uuid), q_bump(uuid,text,int), q_val(uuid,text,text), pick_card_r(text,text), pick_rarity_min(text), pick_slot(text,text) from public;
grant execute on function open_boosters(text,text,int), my_state(), my_quests(), claim_quest(text), quest_event(text) to authenticated;
