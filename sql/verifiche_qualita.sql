-- =====================================================================
-- Registro lotti · «Da verificare» anche per Qualità (31/10/2026)
-- SQL Editor → New query → incolla → Run. Si può rieseguire.
--
-- Qualità può vedere la pagina «Da verificare», segnare i lotti come
-- controllati e annullare i controlli, come Paolo.
-- Nella colonna «Controllo» compare chi l'ha segnato (Paolo o Qualità).
-- Richiede che sia già stato eseguito utenti_paolo_qualita.sql.
-- =====================================================================

drop policy if exists lotti_verifiche_admin on public.lotti_verifiche;
create policy lotti_verifiche_admin on public.lotti_verifiche for select to authenticated
  using (public.lotti_is_admin() or public.lotti_is_qualita());

create or replace function public.admin_segna_verifica(p_lotto text, p_motivo text, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
declare v_chi text;
begin
  if not (public.lotti_is_admin() or public.lotti_is_qualita()) then
    raise exception 'Solo Paolo o Qualità possono segnare i controlli.';
  end if;
  v_chi := case when public.lotti_is_admin() then 'Paolo' else 'Qualità' end;
  insert into public.lotti_verifiche (lotto_id, motivo, nota, verificato_da, verificato_il)
  values (p_lotto, p_motivo, nullif(trim(p_nota), ''), v_chi, now())
  on conflict (lotto_id, motivo) do update set nota = excluded.nota, verificato_da = excluded.verificato_da, verificato_il = now();
end $$;

create or replace function public.admin_annulla_verifica(p_lotto text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.lotti_is_admin() or public.lotti_is_qualita()) then
    raise exception 'Solo Paolo o Qualità possono annullare i controlli.';
  end if;
  delete from public.lotti_verifiche where lotto_id = p_lotto and motivo = p_motivo;
end $$;

revoke all on function public.admin_segna_verifica(text, text, text) from public, anon;
revoke all on function public.admin_annulla_verifica(text, text) from public, anon;
grant execute on function public.admin_segna_verifica(text, text, text) to authenticated;
grant execute on function public.admin_annulla_verifica(text, text) to authenticated;
