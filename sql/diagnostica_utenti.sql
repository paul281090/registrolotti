-- =====================================================================
-- Registro lotti · DIAGNOSTICA (sola lettura, non cambia niente)
-- Serve per preparare l'accesso «Qualità»: mostra come sono fatti
-- oggi la tabella degli utenti e le funzioni che controllano i permessi.
--
-- Supabase → SQL Editor → New query → incolla → Run.
-- Poi in basso a destra del risultato: «Export» → «Download CSV»
-- e manda il file in chat.
-- =====================================================================

select 'colonna' as tipo,
       c.table_name || '.' || c.column_name as nome,
       c.data_type || coalesce(' default ' || c.column_default, '') as testo
from information_schema.columns c
where c.table_schema = 'public'

union all

select 'vincolo', conrelid::regclass::text || ' · ' || conname, pg_get_constraintdef(oid)
from pg_constraint
where connamespace = 'public'::regnamespace and contype in ('c', 'f', 'p', 'u')

union all

select 'funzione', p.proname, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'

union all

select 'policy', tablename || ' · ' || policyname, cmd || ' · ' || coalesce(qual, '') || ' · ' || coalesce(with_check, '')
from pg_policies
where schemaname = 'public'

union all

select 'utente', u.email, coalesce(u.raw_user_meta_data::text, '')
from auth.users u

order by 1, 2;
