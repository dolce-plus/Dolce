-- ============================================================================
--  Dolce+ — 3 clients can book the SAME service at the SAME time
--  Run once in Supabase → SQL Editor. Changes no bookings.
--  Sets "Staff who can do this service" to 3 for every service (Dolce,
--  Polished, Core), and makes 3 the default for new services.
--  A single service can still be changed later in Admin → Services.
-- ============================================================================
begin;
update public.services set staff_count = 3;
alter table public.services alter column staff_count set default 3;
commit;

-- Check: how many services per brand now take 3 clients at once
select brand, count(*) as services, min(staff_count) as min_clients, max(staff_count) as max_clients
  from public.services group by brand order by brand;
