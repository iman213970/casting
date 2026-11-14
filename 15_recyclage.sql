-- CASTING : recyclage des doublons par rareté (comme Kyara).
-- A coller en entier dans Supabase > SQL Editor > New query > Run APRES 14_vite.sql.
-- Peut etre lance plusieurs fois sans risque.
--
-- Tu gardes toujours 1 exemplaire de chaque carte. Popcorns rendus par doublon (memes valeurs que Kyara) :
--   Commune 1, Peu commune 1, Rare 3, Epique 10, Legendaire 40, Mythique 150.
-- Les missions « Recycle » avancent toutes seules (trigger de 9_lot1_boosters_missions.sql).

create or replace function recycle_rarities(rars text[]) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); n int := 0; gain int := 0;
begin
  if uid is null then raise exception 'Connecte-toi'; end if;
  if rars is null or cardinality(rars) = 0 then raise exception 'Choisis au moins une rareté'; end if;
  perform 1 from profiles where id=uid for update;
  select coalesce(sum(i.qty-1),0),
         coalesce(sum((i.qty-1) * case c.r when 'C' then 1 when 'U' then 1 when 'R' then 3 when 'E' then 10 when 'L' then 40 when 'M' then 150 else 0 end),0)
    into n, gain
    from inv i join cards c on c.n=i.n
   where i.user_id=uid and i.qty>1 and c.r = any(rars);
  if n = 0 then raise exception 'Aucun doublon à recycler'; end if;
  update inv i set qty=1 from cards c
   where c.n=i.n and i.user_id=uid and i.qty>1 and c.r = any(rars);
  update profiles set popcorns=popcorns+gain where id=uid;
  return jsonb_build_object('n',n,'gain',gain,'state',my_state());
end $$;

revoke all on function recycle_rarities(text[]) from public;
grant execute on function recycle_rarities(text[]) to authenticated;
