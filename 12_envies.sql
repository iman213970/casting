-- Envies (comme Kyara) : une liste de persos que tu veux. Aucune chance en plus : le booster affiche juste
-- combien de tes envies il peut donner et ta chance d'en avoir une. Une envie obtenue sort toute seule de la liste.
-- A coller dans Supabase > SQL Editor > Run (une seule fois, sans risque si relance).
insert into config(k,v) values ('wish_max',200) on conflict do nothing;

create table if not exists wishes(
  user_id uuid not null references auth.users(id) on delete cascade,
  n int not null,
  created_at timestamptz not null default now(),
  primary key(user_id,n));
alter table wishes enable row level security;

create or replace function my_wishes() returns int[] language sql security definer set search_path=public stable as $$
  select coalesce(array_agg(n order by created_at),'{}') from wishes where user_id=auth.uid() $$;

-- on=true ajoute, on=false retire ; plusieurs cartes d'un coup (album). Les cartes deja possedees sont ignorees.
create or replace function set_wishes(cards int[], on_ boolean) returns int[] language plpgsql security definer set search_path=public as $$
declare room int;
begin
  if auth.uid() is null then raise exception 'Connecte-toi'; end if;
  if on_ then
    room := cfg('wish_max') - (select count(*) from wishes where user_id=auth.uid());
    insert into wishes(user_id,n)
      select auth.uid(), c from (select distinct unnest(cards) c) x
       where exists(select 1 from cards where n=c)
         and not exists(select 1 from inv where user_id=auth.uid() and n=c and qty>0)
         and not exists(select 1 from wishes where user_id=auth.uid() and n=c)
       limit greatest(room,0);
  else
    delete from wishes where user_id=auth.uid() and n=any(cards);
  end if;
  return my_wishes();
end $$;

-- une envie obtenue sort de la liste
create or replace function wishes_on_inv() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.qty>0 then delete from wishes where user_id=new.user_id and n=new.n; end if;
  return new;
end $$;
drop trigger if exists wishes_on_inv on inv;
create trigger wishes_on_inv after insert or update on inv for each row execute function wishes_on_inv();

revoke all on function my_wishes(), set_wishes(int[],boolean) from public;
grant execute on function my_wishes(), set_wishes(int[],boolean) to authenticated;
