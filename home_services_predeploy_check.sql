-- ============================================================================
--  HOME SERVICES — PRE-DEPLOYMENT CHECK  (read-only: changes nothing)
--  Run in Supabase → SQL Editor and send a screenshot of the result.
--  One row per check: installed = yes/no, plus details.
-- ============================================================================
select * from (values
  ('v1  bookings.at_home column',
     (select case when count(*)>0 then 'yes' else 'no' end from information_schema.columns
       where table_schema='public' and table_name='bookings' and column_name='at_home'), ''),
  ('v1  services.home_ok column',
     (select case when count(*)>0 then 'yes' else 'no' end from information_schema.columns
       where table_schema='public' and table_name='services' and column_name='home_ok'), ''),
  ('v2  saved prices (bookings.total_usd)',
     (select case when count(*)>0 then 'yes' else 'no' end from information_schema.columns
       where table_schema='public' and table_name='bookings' and column_name='total_usd'), ''),
  ('v2  price change function',
     (select case when count(*)>0 then 'yes' else 'no' end from pg_proc where proname='staff_change_home_price'), ''),
  ('v2  price lock trigger',
     (select case when count(*)>0 then 'yes' else 'no' end from pg_trigger where tgname='bookings_price_lock'), ''),
  ('v3  services.home_price_usd column',
     (select case when count(*)>0 then 'yes' else 'no' end from information_schema.columns
       where table_schema='public' and table_name='services' and column_name='home_price_usd'), ''),
  ('Home visits switched on (must be none)',
     (select coalesce(string_agg(b.key, ', '), 'none') from public.settings s,
        lateral jsonb_each(case when s.value like '{%' then s.value::jsonb->'brands' else '{}'::jsonb end) b
       where s.key='home_service' and coalesce((b.value->>'enabled')::boolean,false)),
     (select coalesce(left(value,120),'(no setting yet)') from public.settings where key='home_service')),
  ('Services marked for home (home_ok)',
     (select count(*)::text from public.services where coalesce(home_ok,false)), ''),
  ('Bookings in total (unchanged by v3)',
     (select count(*)::text from public.bookings), ''),
  ('Home-visit bookings so far',
     (select count(*)::text from public.bookings where coalesce(at_home,false)), ''),
  ('Services write rules (staff permissions)',
     (select string_agg(policyname||' ['||cmd||']', ', ' order by policyname) from pg_policies
       where schemaname='public' and tablename='services'), '')
) as t(check_item, installed, details);
