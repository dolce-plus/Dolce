-- ============================================================================
--  Discount dates for services and products
--  Run once in Supabase → SQL Editor. Safe to run again.
--
--  Admin → Services / Products now has "Discount starts" and "Discount ends".
--  A discount only counts between those days (both included, Erbil time).
--  No dates = always on, exactly as before.
--
--  This also teaches the two server price checks the same rule, so a client is
--  never charged a discount that has ended (or not started yet):
--    • service_price_now  — the price saved on a booking
--    • product_unit_price — the price on a shop order
-- ============================================================================

alter table public.services add column if not exists discount_starts_on date;
alter table public.services add column if not exists discount_ends_on   date;
alter table public.products add column if not exists discount_starts_on date;
alter table public.products add column if not exists discount_ends_on   date;

-- Today in Erbil (the businesses' own day, not the server's).
create or replace function public.erbil_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Baghdad')::date;
$$;

-- Is a discount on today?
create or replace function public.discount_on_now(p_pct numeric, p_from date, p_until date)
returns boolean language sql stable as $$
  select coalesce(p_pct, 0) > 0
     and (p_from  is null or p_from  <= public.erbil_today())
     and (p_until is null or p_until >= public.erbil_today());
$$;

create or replace function public.service_price_now(p_brand text, p_service_id text)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select case when public.discount_on_now(s.discount_percent, s.discount_starts_on, s.discount_ends_on)
              then round(s.price_usd * (1 - s.discount_percent / 100.0))
              else s.price_usd end
    from public.services s
   where s.id = p_service_id and s.brand = p_brand
   limit 1;
$$;

create or replace function public.product_unit_price(p public.products)
returns numeric language sql stable as $$
  select case when public.discount_on_now(p.discount_percent, p.discount_starts_on, p.discount_ends_on)
              then round(p.price_usd * (100 - p.discount_percent) / 100.0)
              else p.price_usd end;
$$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'services_discount_dates_ck') then
    alter table public.services add constraint services_discount_dates_ck
      check (discount_starts_on is null or discount_ends_on is null or discount_ends_on >= discount_starts_on);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'products_discount_dates_ck') then
    alter table public.products add constraint products_discount_dates_ck
      check (discount_starts_on is null or discount_ends_on is null or discount_ends_on >= discount_starts_on);
  end if;
end $$;

-- Check: one row that says "ok"
select case when count(*) = 4 then 'ok' else 'columns missing' end as discount_dates
  from information_schema.columns
 where table_schema = 'public' and table_name in ('services','products')
   and column_name in ('discount_starts_on','discount_ends_on');
