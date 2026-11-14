-- CASTING boutique : Avant-premiere, Deep Cuts, Mini, Coffret et Prestige, payes en Popcorns.
-- A coller en entier dans Supabase > SQL Editor > New query > Run APRES 9_lot1_boosters_missions.sql.
-- Peut etre lance plusieurs fois sans risque. Les prix deja reglés dans config ne sont pas ecrases.
--
-- Prix calques sur la boutique Kyara :
--   Avant-premiere 750 (Kyara Hall of Fame 750) : 5 cartes parmi les 3 000 persos les plus connus, R R R R E,
--                  Legendaires et Mythiques x3,5 -> environ 37 % de Legendaire et 8 % de Mythique par booster (Kyara 39,4 / 7,7)
--   Prestige 575   (Kyara Prestige 575) : 5 cartes C C C U R, Legendaires et Mythiques x2,7
--   Coffret 550    (Kyara Coffret 550) : 20 cartes, 11 C, 5 U, 3 R, 1 E garanties
--   Mini 100       (Kyara Mini-booster 100) : 3 cartes C U R
--   Deep Cuts 100  (Kyara Deep Cuts 100) : 5 cartes C C C U R parmi les persos de rang 1 000 et plus (moins connus)

insert into config(k,v) values ('shop_coffret',550),('shop_prestige',575),('shop_mini',100),('shop_avp',750),('shop_deep',100)
  on conflict(k) do nothing;

-- Une carte pour un slot de boutique : rarete au moins minr, Legendaires et Mythiques multipliees par boost,
-- seulement parmi les top premiers numeros si top n'est pas null, seulement apres le numero lo si lo n'est pas null
-- (les numeros suivent la notoriete).
drop function if exists shop_pick(text,int,numeric);
create or replace function shop_pick(minr text, top int, boost numeric, lo int default null) returns int language plpgsql volatile set search_path=public as $$
declare allowed text := substr('CURELM', position(minr in 'CURELM')); ch text; tot numeric := 0; x numeric; acc numeric := 0; rar text := minr; c int; i int;
begin
  foreach ch in array string_to_array(allowed,null) loop tot := tot + cfg('p_'||ch) * (case when ch in ('L','M') then boost else 1 end); end loop;
  x := random()*tot;
  foreach ch in array string_to_array(allowed,null) loop
    acc := acc + cfg('p_'||ch) * (case when ch in ('L','M') then boost else 1 end);
    if x < acc then rar := ch; exit; end if;
  end loop;
  select n into c from cards where r=rar and (top is null or n<=top) and (lo is null or n>lo) order by random() limit 1;
  if c is not null then return c; end if;
  for i in reverse position(rar in 'CURELM')-1 .. position(minr in 'CURELM') loop
    select n into c from cards where r=substr('CURELM',i,1) and (top is null or n<=top) and (lo is null or n>lo) order by random() limit 1;
    if c is not null then return c; end if;
  end loop;
  return (select n from cards where (top is null or n<=top) and (lo is null or n>lo) order by random() limit 1);
end $$;

-- ---------- etat du joueur (remplace celui de 9_lot1_boosters_missions.sql) : ajoute les prix de la boutique ----------
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
    'shop',jsonb_build_object('coffret',cfg('shop_coffret'),'prestige',cfg('shop_prestige'),'mini',cfg('shop_mini'),'avp',cfg('shop_avp'),'deep',cfg('shop_deep')),
    'golden_in',p.golden_in,'golden_every',cfg('golden_every'),
    'quests',jsonb_build_object('claimable',q->'claimable',
       'daily_done',(select count(*) from jsonb_array_elements(q->'quests') x where x->>'kind'='daily' and (x->>'done')::bool),
       'daily_total',(select count(*) from jsonb_array_elements(q->'quests') x where x->>'kind'='daily'),
       'streak_day',q->'streak'->'day','streak_ready',not (q->'streak'->>'claimed_today')::bool),
    'odds',jsonb_build_object('M',cfg('p_M'),'L',cfg('p_L'),'E',cfg('p_E'),'R',cfg('p_R'),'U',cfg('p_U'),'C',cfg('p_C')),
    'inv', coalesce((select jsonb_object_agg(n::text,qty) from inv where user_id=p.id),'{}'::jsonb));
end $$;

-- ---------- ouverture (remplace celle de 9_lot1_boosters_missions.sql) ----------
-- Slots : normal C C C U R, pack du jour et booster dore C C U R E, god pack E E E E M.
-- Boutique (kind='shop', genre = produit) : un seul a la fois, pas de god pack. Compte pour la Mythique sure et pour le dore
-- (comme Kyara) : un produit de boutique dore garde ses cartes mais son dernier slot devient Epique ou mieux.
create or replace function open_boosters(kind text, genre text default null, qty int default 1) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p profiles; picks int[]; c int; b int; i int; slots text; pity_hit bool; has bool; was_owned bool; seen int[] := '{}';
        price int; sm int; gi int; golden bool; god bool; use_free int; cres jsonb; all_b jsonb := '[]'::jsonb;
        sp text; gain int := 0; bonus int; cr text; n_e int := 0; n_l int := 0; n_m int := 0; n_new int := 0;
begin
  if qty not in (1,5,10) then raise exception 'Quantité invalide'; end if;
  if kind='shop' then
    if qty<>1 then raise exception 'Un seul à la fois en boutique'; end if;
    if genre is null or genre not in ('coffret','prestige','mini','avp','deep') then raise exception 'Produit inconnu'; end if;
    sp := genre; genre := null;
  end if;
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
  elsif kind='shop' then
    price := cfg('shop_'||sp);
    if p.popcorns < price then raise exception 'Pas assez de Popcorns'; end if;
    update profiles set popcorns=popcorns-price where id=p.id;
  elsif kind='paid' then
    price := (case when genre is null then cfg('price') else cfg('gprice') end) * qty;
    if p.popcorns < price then raise exception 'Pas assez de Popcorns'; end if;
    update profiles set popcorns=popcorns-price where id=p.id;
  else raise exception 'Type de booster inconnu'; end if;

  sm := p.since_mythic; gi := p.golden_in;
  for b in 1..qty loop
    golden := false; god := false;
    if kind='shop' then
      slots := case sp when 'coffret' then 'CCCCCCCCCCCUUUUURRRE' when 'mini' then 'CUR' when 'avp' then 'RRRRE' else 'CCCUR' end;
      if gi <= 0 then golden := true; slots := left(slots, length(slots)-1) || 'E'; end if;
    elsif kind='daily' then slots := 'CCURE';
    elsif random()*100000 < cfg('god_chance') then god := true; slots := 'EEEEM';
    elsif gi <= 0 then golden := true; slots := 'CCURE';
    else slots := 'CCCUR'; end if;
    if kind <> 'daily' then gi := case when golden then cfg('golden_every') else greatest(gi-1,0) end; end if;

    picks := '{}'; pity_hit := sm+1 >= cfg('pity');
    for i in 1..length(slots) loop
      if kind='shop' then
        picks := picks || shop_pick(substr(slots,i,1), case when sp='avp' then 3000 end, case sp when 'prestige' then 2.7 when 'avp' then 3.5 else 1 end, case when sp='deep' then 1000 end);
      else picks := picks || pick_slot(substr(slots,i,1), genre); end if;
    end loop;
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
revoke all on function shop_pick(text,int,numeric), open_boosters(text,text,int), my_state() from public;
grant execute on function open_boosters(text,text,int), my_state() to authenticated;
