-- =====================================================================
-- Registro lotti · Storico modifiche + Da verificare (30/10/2026)
-- Da eseguire una volta in Supabase (SQL Editor → New query → Run).
-- Si può rieseguire senza problemi. Non modifica i lotti esistenti.
--
--  * lotti_storico: ogni registrazione, modifica, spostamento nel cestino,
--    ripristino o eliminazione di lotti e ingressi (consegne frazionate),
--    con utente, data/ora e valori prima/dopo. Lo scrivono i trigger,
--    nessuno lo può modificare dal sito. Lo legge solo l'admin.
--    Lo storico parte da quando si esegue questo script.
--  * lotti_verifiche: i lotti della pagina «Da verificare» segnati come
--    controllati dall'admin, con la nota.
-- =====================================================================

-- ---------- STORICO ----------
create table if not exists public.lotti_storico (
  id       bigserial primary key,
  il       timestamptz not null default now(),
  utente   text,
  tabella  text not null,
  azione   text not null,
  lotto_id text,
  lotto    text,
  vecchio  jsonb,
  nuovo    jsonb
);
create index if not exists lotti_storico_il on public.lotti_storico (il desc);
create index if not exists lotti_storico_lotto on public.lotti_storico (lotto_id);
alter table public.lotti_storico enable row level security;
drop policy if exists lotti_storico_admin on public.lotti_storico;
create policy lotti_storico_admin on public.lotti_storico for select to authenticated
  using (coalesce(auth.jwt() ->> 'email', '') = 'admin@lotti.local');
grant select on public.lotti_storico to authenticated;
revoke insert, update, delete on public.lotti_storico from authenticated, anon;

create or replace function public.lotti_storico_scrivi()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  v_rec jsonb := coalesce(v_new, v_old);
  v_ign text[] := array['created_at', 'updated_at', 'aggiornato_il', 'modificato_il'];
  v_pre jsonb := '{}'; v_dopo jsonb := '{}';
  k text; v_az text; v_lotto_id text; v_lotto text;
  v_utente text := coalesce(auth.jwt() ->> 'email', current_user);
begin
  if tg_table_name = 'lotti' then
    v_lotto_id := v_rec ->> 'id';
    v_lotto    := v_rec ->> 'lotto_trentin';
  else
    v_lotto_id := v_rec ->> 'lotto_id';
    select l.lotto_trentin into v_lotto from public.lotti l where l.id::text = v_lotto_id;
    if tg_op = 'DELETE' and v_lotto is null then return null; end if;   -- ingresso cancellato insieme al suo lotto (già registrato)
  end if;

  if tg_op = 'INSERT' then
    v_az := case when tg_table_name = 'lotti' then 'Lotto registrato' else 'Ingresso aggiunto' end;
    v_dopo := v_new;
  elsif tg_op = 'DELETE' then
    v_az := case when tg_table_name = 'lotti' then 'Eliminato definitivamente' else 'Ingresso eliminato' end;
    v_pre := v_old;
  else
    for k in select jsonb_object_keys(v_new) loop
      if not (k = any(v_ign)) and (v_old -> k) is distinct from (v_new -> k) then
        v_pre  := v_pre  || jsonb_build_object(k, v_old -> k);
        v_dopo := v_dopo || jsonb_build_object(k, v_new -> k);
      end if;
    end loop;
    if v_dopo = '{}'::jsonb then return null; end if;                 -- niente di cambiato
    if tg_table_name = 'lotti' and v_dopo ? 'eliminato_il' then
      v_az := case when v_new ->> 'eliminato_il' is null then 'Ripristinato dal cestino' else 'Spostato nel cestino' end;
    elsif tg_table_name = 'lotti' and (v_dopo - array['qta', 'qta_kg', 'data_arrivo', 'temp', 'igiene', 'integrita', 'addetto', 'ddt', 'frazionata']) = '{}'::jsonb
          and (v_new ->> 'frazionata')::boolean is true then
      v_az := 'Totali partita aggiornati';
    else
      v_az := case when tg_table_name = 'lotti' then 'Lotto modificato' else 'Ingresso modificato' end;
    end if;
  end if;

  insert into public.lotti_storico (utente, tabella, azione, lotto_id, lotto, vecchio, nuovo)
  values (v_utente, tg_table_name, v_az, v_lotto_id, v_lotto, nullif(v_pre, '{}'::jsonb), nullif(v_dopo, '{}'::jsonb));
  return null;
end $$;

drop trigger if exists lotti_storico_trg on public.lotti;
create trigger lotti_storico_trg after insert or update or delete on public.lotti
  for each row execute function public.lotti_storico_scrivi();
drop trigger if exists ingressi_storico_trg on public.ingressi;
create trigger ingressi_storico_trg after insert or update or delete on public.ingressi
  for each row execute function public.lotti_storico_scrivi();

-- ---------- DA VERIFICARE ----------
create table if not exists public.lotti_verifiche (
  lotto_id       text not null,
  motivo         text not null,
  nota           text,
  verificato_da  text,
  verificato_il  timestamptz not null default now(),
  primary key (lotto_id, motivo)
);
alter table public.lotti_verifiche enable row level security;
drop policy if exists lotti_verifiche_admin on public.lotti_verifiche;
create policy lotti_verifiche_admin on public.lotti_verifiche for select to authenticated
  using (coalesce(auth.jwt() ->> 'email', '') = 'admin@lotti.local');
grant select on public.lotti_verifiche to authenticated;

create or replace function public.admin_segna_verifica(p_lotto text, p_motivo text, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'admin@lotti.local' then raise exception 'Solo l''admin può segnare i controlli.'; end if;
  insert into public.lotti_verifiche (lotto_id, motivo, nota, verificato_da, verificato_il)
  values (p_lotto, p_motivo, nullif(trim(p_nota), ''), 'Admin', now())
  on conflict (lotto_id, motivo) do update set nota = excluded.nota, verificato_da = excluded.verificato_da, verificato_il = now();
end $$;

create or replace function public.admin_annulla_verifica(p_lotto text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'admin@lotti.local' then raise exception 'Solo l''admin può annullare i controlli.'; end if;
  delete from public.lotti_verifiche where lotto_id = p_lotto and motivo = p_motivo;
end $$;

revoke all on function public.admin_segna_verifica(text, text, text) from public, anon;
revoke all on function public.admin_annulla_verifica(text, text) from public, anon;
grant execute on function public.admin_segna_verifica(text, text, text) to authenticated;
grant execute on function public.admin_annulla_verifica(text, text) to authenticated;
