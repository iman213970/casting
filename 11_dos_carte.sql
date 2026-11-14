-- Dos des cartes (comme Kyara) : « Tu l'as depuis » + date.
-- A coller dans Supabase > SQL Editor > Run (une seule fois, sans risque si relance).
-- Les cartes deja possedees prennent la date du jour ou ce fichier est lance (l'info n'existait pas avant).
alter table inv add column if not exists first_at timestamptz not null default now();

create or replace function card_since(card int) returns timestamptz language sql security definer set search_path=public stable as $$
  select first_at from inv where user_id=auth.uid() and n=card and qty>0 $$;

revoke all on function card_since(int) from public;
grant execute on function card_since(int) to authenticated;
