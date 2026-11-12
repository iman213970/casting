-- CASTING etape 1 (suite) : boosters bonus a part + bonus Legendaire/Mythique a CHAQUE obtention.
-- A coller en entier dans Supabase > SQL Editor > New query > Run APRES 5_etape1.sql. Peut etre lance plusieurs fois sans risque.

-- Compteur de boosters bonus (missions, series de connexion...) : pas de plafond, pas de recharge
alter table profiles add column if not exists bonus_stock int not null default 0;

drop function if exists my_state();
create or replace function my_state() returns jsonb language plpgsql security definer set search_path=public as $$
declare p profiles; step interval := make_interval(mins=>cfg('free_minutes')); nxt int;
begin
  perform refill(auth.uid());
  select * into p from profiles where id=auth.uid();
  if p.id is null then return null; end if;
  nxt := case when p.free_stock >= cfg('free_max') then null else greatest(0, ceil(extract(epoch from (p.free_at + step - now()))))::int end;
  return jsonb_build_object('name',p.name,'popcorns',p.popcorns,'boosters',p.boosters,'pity',p.since_mythic,
    'pity_max',cfg('pity'),'free',p.free_stock,'bonus',p.bonus_stock,'free_max',cfg('free_max'),'free_next',nxt,
    'daily_ready', coalesce(p.last_daily,'1970-01-01') < current_date,'daily_theme',daily_theme(),'themes',to_jsonb(themes()),
    'price',cfg('price'),'gprice',cfg('gprice'),'bonus_L',cfg('bonus_L'),'bonus_M',cfg('bonus_M'),
    'odds',jsonb_build_object('M',cfg('p_M'),'L',cfg('p_L'),'E',cfg('p_E'),'R',cfg('p_R'),'U',cfg('p_U'),'C',cfg('p_C')),
    'inv', coalesce((select jsonb_object_agg(n::text,qty) from inv where user_id=p.id),'{}'::jsonb));
end $$;

-- Ouverture de 1, 5 ou 10 boosters d'un coup
create or replace function open_boosters(kind text, genre text default null, qty int default 1) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p profiles; picks int[]; rar char; c int; i int; b int; ch char; minr char; allowed text; tot int; x int; acc int;
        pity_hit bool; has bool; was_owned bool; seen int[] := '{}'; size int := cfg('booster_size'); price int;
        sm int; use_free int; bres jsonb; cres jsonb; all_b jsonb := '[]'::jsonb; gain int := 0; bonus int; cr char;
begin
  if qty not in (1,5,10) then raise exception 'Quantité invalide'; end if;
  perform refill(auth.uid());
  select * into p from profiles where id=auth.uid() for update;
  if p.id is null then raise exception 'Connecte-toi'; end if;
  if genre is not null and not (genre = any(themes())) then raise exception 'Thème inconnu'; end if;
  minr := 'R';
  if kind='daily' then
    if qty<>1 then raise exception 'Un seul pack du jour'; end if;
    if p.last_daily = current_date then raise exception 'Pack du jour déjà ouvert'; end if;
    update profiles set last_daily=current_date where id=p.id; genre := daily_theme(); minr := 'E';
  elsif kind='free' then
    if p.free_stock + p.bonus_stock < qty then raise exception 'Pas assez de boosters gratuits'; end if;
    -- on consomme d'abord le stock qui se recharge (il repart tout de suite), puis les boosters bonus
    use_free := least(p.free_stock, qty);
    update profiles set free_stock=free_stock-use_free, bonus_stock=bonus_stock-(qty-use_free),
      free_at = case when free_stock>=cfg('free_max') then now() else free_at end where id=p.id;
  elsif kind='paid' then
    price := (case when genre is null then cfg('price') else cfg('gprice') end) * qty;
    if p.popcorns < price then raise exception 'Pas assez de Popcorns'; end if;
    update profiles set popcorns=popcorns-price where id=p.id;
  else raise exception 'Type de booster inconnu'; end if;

  sm := p.since_mythic;
  allowed := substr('CURELM', position(minr in 'CURELM'));
  for b in 1..qty loop
    picks := '{}'; pity_hit := sm+1 >= cfg('pity');
    for i in 1..size loop
      rar := pick_rarity(); c := pick_card(rar,genre);
      if c is null then c := pick_card('C',genre); end if;
      if c is null then c := (select n from cards where genre is null or genre=any(g) order by random() limit 1); end if;
      picks := picks || c;
    end loop;
    if not exists(select 1 from cards where n=any(picks) and position(r in allowed)>0) then
      tot := 0; foreach ch in array string_to_array(allowed,null) loop tot := tot + cfg('p_'||ch); end loop;
      x := 1+floor(random()*tot)::int; acc := 0; rar := minr;
      foreach ch in array string_to_array(allowed,null) loop acc := acc + cfg('p_'||ch); if x<=acc then rar:=ch; exit; end if; end loop;
      c := coalesce(pick_card(rar,genre), pick_card(minr,genre)); if c is not null then picks[size] := c; end if;
    end if;
    if pity_hit and not exists(select 1 from cards where n=any(picks) and r='M') then
      c := pick_card('M',genre); if c is not null then picks[size] := c; end if;
    end if;
    has := exists(select 1 from cards where n=any(picks) and r='M');
    cres := '[]'::jsonb;
    foreach c in array picks loop
      was_owned := exists(select 1 from inv where user_id=p.id and n=c) or c=any(seen);
      seen := seen || c;
      insert into inv(user_id,n,qty) values(p.id,c,1) on conflict(user_id,n) do update set qty=inv.qty+1;
      select r into cr from cards where n=c;
      bonus := case when cr='L' then cfg('bonus_L') when cr='M' then cfg('bonus_M') else 0 end;
      gain := gain + bonus;
      cres := cres || jsonb_build_object('n',c,'new',not was_owned,'bonus',bonus);
    end loop;
    sm := case when has then 0 else sm+1 end;
    all_b := all_b || jsonb_build_object('cards',cres,'pity_hit',pity_hit and has);
  end loop;
  update profiles set boosters=boosters+qty, since_mythic=sm, popcorns=popcorns+gain where id=p.id;
  return jsonb_build_object('boosters',all_b,'gain',gain,'state',my_state());
end $$;

-- Combien de joueurs possedent une carte (pour le dos de la carte)
create or replace function card_owners(card int) returns int language sql security definer set search_path=public stable as $$
  select count(distinct user_id)::int from inv where n=card and qty>0 $$;

revoke all on function open_boosters, card_owners, my_state, refill from public;
grant execute on function open_boosters, card_owners, my_state to authenticated;

-- Chances par carte tirée, identiques à Kyara (échelle 10 000) : C 62 %, U 25 %, R 11,4 %, E 1,4 %, L 0,15 %, M 0,03 %
insert into config(k,v) values ('p_C',6202),('p_U',2500),('p_R',1140),('p_E',140),('p_L',15),('p_M',3)
  on conflict(k) do update set v=excluded.v;
