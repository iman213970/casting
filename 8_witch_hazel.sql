-- Looney Tunes : ajout de Witch Hazel (Epique).
-- A coller dans Supabase > SQL Editor > Run (peut etre relance sans risque).
insert into cards(n,r,g) values
(10892,'E','{"Comedy"}')
on conflict(n) do update set r=excluded.r;
