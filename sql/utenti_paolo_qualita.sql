-- =====================================================================
-- Registro lotti · Accessi: Admin → Paolo, nuovo utente Qualità (30/10/2026)
--
-- PRIMA di eseguire lo script:
--   Supabase → Authentication → Users → «Add user» → «Create new user»
--     Email:    qualita@lotti.local
--     Password: una provvisoria (almeno 6 caratteri)
--     «Auto Confirm User» acceso
--   Al primo accesso dal sito Qualità sceglierà la sua password.
--
-- POI: SQL Editor → New query → incolla questo script → Run.
-- Si può rieseguire senza problemi. Tocca solo le tabelle e le funzioni
-- del registro lotti (non il programma di magazzino).
--
-- Cosa fa:
--  * l'utente admin si chiama «Paolo» (stesso account e stessa password);
--  * aggiunge il ruolo «qualita» e l'utente Qualità;
--  * Qualità vede anche il cestino, può ripristinare i lotti eliminati
--    ed esportare il backup. Tutto il resto resta riservato a Paolo
--    (importazione, eliminazione definitiva, utenti, medie, regole...).
--    Per modificare/eliminare lotti vale il blocco dei 10 giorni.
-- =====================================================================

-- 1) ruolo «qualita» ammesso nella tabella utenti
alter table public.lotti_utenti drop constraint if exists lotti_utenti_ruolo_check;
alter table public.lotti_utenti add constraint lotti_utenti_ruolo_check
  check (ruolo = any (array['admin', 'operatore', 'qualita']));

-- 2) Admin → Paolo, nuovo utente Qualità
update public.lotti_utenti set nome = 'Paolo' where lower(email) = 'admin@lotti.local';
insert into public.lotti_utenti (email, nome, ruolo, magazzino, deve_cambiare_pwd)
values ('qualita@lotti.local', 'Qualità', 'qualita', null, true)
on conflict (email) do update set nome = excluded.nome, ruolo = excluded.ruolo, magazzino = null;

-- 3) controllo «Paolo oppure Qualità»
create or replace function public.lotti_is_qualita()
returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((public.lotti_me()).ruolo = 'qualita', false) $$;

create or replace function public.lotti_chiedi_admin_o_qualita()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.lotti_is_admin() or public.lotti_is_qualita()) then
    raise exception 'Operazione riservata a Paolo o Qualità.';
  end if;
end $$;
grant execute on function public.lotti_is_qualita() to authenticated;
grant execute on function public.lotti_chiedi_admin_o_qualita() to authenticated;

-- 4) Qualità vede i lotti nel cestino (e i loro ingressi)
drop policy if exists lotti_lettura on public.lotti;
create policy lotti_lettura on public.lotti for select to authenticated
  using ((public.lotti_ruolo() is not null) and ((eliminato_il is null) or public.lotti_is_admin() or public.lotti_is_qualita()));

drop policy if exists ingressi_lettura on public.ingressi;
create policy ingressi_lettura on public.ingressi for select to authenticated
  using ((public.lotti_ruolo() is not null) and (public.lotti_is_admin() or public.lotti_is_qualita()
         or exists (select 1 from public.lotti l where l.id = ingressi.lotto_id and l.eliminato_il is null)));

-- 5) ripristino dal cestino: Paolo o Qualità
create or replace function public.ripristina_lotto(p_id uuid, p_progressivo integer default null::integer)
returns lotti language plpgsql security definer set search_path = public as $function$
declare r public.lotti; v_prog int;
begin
  perform public.lotti_chiedi_admin_o_qualita();
  perform pg_advisory_xact_lock(hashtext('lotti_assegnazione'));
  select * into r from public.lotti where id = p_id and eliminato_il is not null for update;
  if not found then raise exception 'Questo lotto non è nel cestino.'; end if;
  v_prog := r.progressivo;
  if r.progressivo is not null then
    v_prog := coalesce(p_progressivo, r.progressivo);
    if v_prog < 1 then raise exception 'Il numero del lotto deve essere 1 o più.'; end if;
    if exists (select 1 from public.lotti where anno = r.anno and progressivo = v_prog and eliminato_il is null) then
      raise exception 'Il lotto % è già stato assegnato a un altro lotto: scegli un altro numero.', public.lotti_codice(r.anno, v_prog, null);
    end if;
  end if;
  update public.lotti set eliminato_il = null, eliminato_da = null, progressivo = v_prog,
         lotto_trentin = public.lotti_codice(r.anno, v_prog, lotto_fornitore)
  where id = p_id returning * into r;
  perform public.lotti_bump();
  return r;
end $function$;

-- 6) esporta backup: Paolo o Qualità (l'importazione resta solo a Paolo)
create or replace function public.admin_esporta_dati()
returns jsonb language plpgsql security definer set search_path = public as $function$
declare r jsonb;
begin
  perform public.lotti_chiedi_admin_o_qualita();
  r := jsonb_build_object(
    'formato', 'registro-lotti',
    'versione', 1,
    'esportato_il', now(),
    'anno_lotto', coalesce((select valore from public.impostazioni where chiave = 'anno_lotto'), '27'),
    'lotti',    coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at, l.id) from public.lotti l), '[]'::jsonb),
    'ingressi', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at, i.id) from public.ingressi i), '[]'::jsonb),
    'voci',     coalesce((select jsonb_agg(to_jsonb(v)) from public.lotti_voci v), '[]'::jsonb),
    'medie',    coalesce((select jsonb_agg(to_jsonb(m) order by m.ordine) from public.lotti_medie m), '[]'::jsonb),
    'regole',   coalesce((select jsonb_agg(to_jsonb(g) order by g.ordine) from public.lotti_regole g), '[]'::jsonb));
  insert into public.impostazioni (chiave, valore) values ('ultimo_backup', now()::text)
  on conflict (chiave) do update set valore = excluded.valore;
  perform public.lotti_bump();
  return r;
end $function$;

-- 7) i controlli segnati in «Da verificare» d'ora in poi risultano fatti da Paolo
create or replace function public.admin_segna_verifica(p_lotto text, p_motivo text, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'admin@lotti.local' then raise exception 'Solo Paolo può segnare i controlli.'; end if;
  insert into public.lotti_verifiche (lotto_id, motivo, nota, verificato_da, verificato_il)
  values (p_lotto, p_motivo, nullif(trim(p_nota), ''), 'Paolo', now())
  on conflict (lotto_id, motivo) do update set nota = excluded.nota, verificato_da = excluded.verificato_da, verificato_il = now();
end $$;

-- controllo finale: deve mostrare 4 utenti (Paolo, Qualità, Spedizioni, Stagionatura)
select u.email, u.nome, u.ruolo, u.magazzino,
       case when a.id is null then 'MANCA in Authentication → Users' else 'ok' end as account
from public.lotti_utenti u left join auth.users a on lower(a.email) = lower(u.email)
order by u.ruolo, u.nome;
