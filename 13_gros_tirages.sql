-- CASTING : fil « Gros tirages » de l'Accueil (comme « En direct · Légendaires et Mythiques » de Kyara).
-- A coller en entier dans Supabase > SQL Editor > New query > Run. Peut etre lance plusieurs fois sans risque.
--
-- Chaque fois qu'un joueur gagne une Legendaire ou une Mythique (ouverture de booster), une ligne est ajoutee
-- dans big_pulls. L'Accueil affiche les 24 dernieres, avec le pseudo et « il y a N min ».
-- Les doublons comptent aussi (comme Kyara : c'est le tirage qui compte, pas la nouveaute).

create table if not exists big_pulls(
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  n int not null,
  at timestamptz not null default now()
);
create index if not exists big_pulls_at on big_pulls(at desc);
alter table big_pulls enable row level security;   -- pas de lecture directe : tout passe par big_pulls()

-- Declencheur sur inv : une ligne quand la quantite d'une L ou d'une M augmente.
-- Pour un futur echange ou une vente au marche, faire  set local casting.no_pull_log = '1'  avant de bouger inv.
create or replace function big_pull_log() returns trigger language plpgsql security definer set search_path=public as $$
declare rr text;
begin
  if tg_op = 'UPDATE' and new.qty <= old.qty then return new; end if;
  if coalesce(current_setting('casting.no_pull_log', true), '') = '1' then return new; end if;
  select r into rr from cards where n = new.n;
  if rr in ('L','M') then insert into big_pulls(user_id, n) values (new.user_id, new.n); end if;
  return new;
end $$;
drop trigger if exists big_pull_log on inv;
create trigger big_pull_log after insert or update of qty on inv for each row execute function big_pull_log();

-- Les derniers gros tirages, pour tous les joueurs connectes.
create or replace function big_pulls(lim int default 24) returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(x order by at desc), '[]'::jsonb) from (
    select b.at, jsonb_build_object('n', b.n, 'name', coalesce(p.name, '?'), 'ago', greatest(0, extract(epoch from now() - b.at))::int) x
    from big_pulls b join profiles p on p.id = b.user_id
    order by b.at desc limit least(greatest(lim, 1), 50)
  ) t;
$$;
revoke all on function big_pulls(int) from public;
grant execute on function big_pulls(int) to authenticated;

-- Menage : on ne garde que les 500 derniers.
delete from big_pulls where id not in (select id from big_pulls order by at desc limit 500);
