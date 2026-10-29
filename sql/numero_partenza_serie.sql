-- =====================================================================
-- Registro lotti · numero di partenza della serie (29/10/2026)
-- Da eseguire una volta in Supabase (SQL Editor → New query → Run).
-- Si può rieseguire senza problemi.
--
-- Cosa fa:
--  * tabella lotti_serie: per ogni anno, il numero da cui parte la serie
--    (es. anno 26, inizio 120 → il primo lotto sarà 26P120);
--  * funzione admin_imposta_inizio_serie: la usa solo l'admin dal sito
--    (Conteggio lotti → "Anno e numero di partenza");
--  * trigger sui lotti: se il numero assegnato è più basso del numero di
--    partenza, lo sposta al primo numero libero da lì in su.
--    I lotti già registrati non vengono toccati.
--    Il 1° gennaio la serie nuova (27P, 28P…) riparte da 1.
-- =====================================================================

create table if not exists public.lotti_serie (
  anno          int primary key,
  inizio        int not null default 1 check (inizio >= 1),
  aggiornato_il timestamptz not null default now()
);
alter table public.lotti_serie enable row level security;
drop policy if exists lotti_serie_lettura on public.lotti_serie;
create policy lotti_serie_lettura on public.lotti_serie for select to authenticated using (true);
grant select on public.lotti_serie to authenticated;

create or replace function public.admin_imposta_inizio_serie(p_anno int, p_inizio int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'admin@lotti.local' then
    raise exception 'Solo l''admin può impostare il numero di partenza della serie.';
  end if;
  if p_anno is null or p_anno < 20 or p_anno > 99 then raise exception 'Anno non valido.'; end if;
  if p_inizio is null or p_inizio < 1 or p_inizio > 99999 then raise exception 'Numero di partenza non valido.'; end if;
  insert into public.lotti_serie (anno, inizio, aggiornato_il) values (p_anno, p_inizio, now())
  on conflict (anno) do update set inizio = excluded.inizio, aggiornato_il = now();
end $$;
revoke all on function public.admin_imposta_inizio_serie(int, int) from public, anon;
grant execute on function public.admin_imposta_inizio_serie(int, int) to authenticated;

create or replace function public.lotti_applica_inizio_serie()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_inizio int; n int;
begin
  if new.progressivo is null then return new; end if;                      -- TRENTIN: nessun lotto interno
  if tg_op = 'UPDATE' and old.progressivo is not null then return new; end if;  -- modifiche e ripristini: numero lasciato com'è
  select inizio into v_inizio from public.lotti_serie where anno = new.anno;
  if v_inizio is null or new.progressivo >= v_inizio then return new; end if;
  perform pg_advisory_xact_lock(hashtext('lotti_serie_' || new.anno::text));
  n := v_inizio;
  while exists (select 1 from public.lotti
                 where anno = new.anno and progressivo = n and eliminato_il is null
                   and id is distinct from new.id) loop
    n := n + 1;
  end loop;
  new.progressivo   := n;
  new.lotto_trentin := lpad(new.anno::text, 2, '0') || 'P' || n;
  return new;
end $$;

drop trigger if exists lotti_inizio_serie on public.lotti;
create trigger lotti_inizio_serie
  before insert or update of progressivo on public.lotti
  for each row execute function public.lotti_applica_inizio_serie();
