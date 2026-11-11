-- ============================================================================
--  HOME SERVICES v4 — "from $X" starting prices.  Run once, after v3.
--  Adds services.home_price_from (true = show "from"). The request is saved
--  at that starting price; reception confirms the final price (with the
--  client's agreement) before confirming. Nothing else changes.
-- ============================================================================
begin;
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='services' and column_name='home_price_usd') then
    raise exception 'Run supabase_migration_home_service_v3.sql first.';
  end if;
end $$;
alter table public.services add column if not exists home_price_from boolean not null default false;
commit;

-- Check (should list 1 row):
select column_name from information_schema.columns
 where table_schema='public' and table_name='services' and column_name='home_price_from';
