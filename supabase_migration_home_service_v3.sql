-- ============================================================================
--  HOME SERVICES v3 — a separate home-service price per service.
--  Run once in Supabase → SQL Editor, AFTER supabase_migration_home_service.sql
--  and supabase_migration_home_service_v2.sql. Safe to run more than once.
--  Home visits stay OFF (nothing here switches them on).
--
--  * services.home_price_usd — the price when done at the client's home,
--    used exactly as entered (no discount). Empty = not offered at home for
--    Dolce/Polished (CORE stays on WhatsApp). Clinic / salon / studio prices
--    and existing bookings are untouched.
--  * A client's home-visit request saves: home-service price + travel fee
--    (by area, from settings) = total. The travel fee is added once.
-- ============================================================================

begin;   -- all or nothing: an error anywhere below changes nothing

-- ---- 0. Needs v1 + v2 first (stops here, changing nothing, if they are missing)
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='at_home') then
    raise exception 'Run supabase_migration_home_service.sql first (v1 is missing).';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='total_usd')
     or not exists (select 1 from pg_proc where proname='staff_change_home_price') then
    raise exception 'Run supabase_migration_home_service_v2.sql first (v2 is missing).';
  end if;
end $$;

-- ---- 1. Column --------------------------------------------------------------
alter table public.services add column if not exists home_price_usd numeric(10,2);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'services_home_price_ck') then
    alter table public.services add constraint services_home_price_ck check (home_price_usd is null or home_price_usd >= 0);
  end if;
end $$;

-- ---- 2. Booking guard: a home visit uses the HOME price ------------------------
create or replace function public.booking_request_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cfg jsonb; bcfg jsonb; area jsonb; price numeric;
begin
  -- Staff, the SQL editor and the server: only fill in prices that are missing.
  if public.is_staff() or public.request_role() not in ('anon', 'authenticated') then
    if new.service_price_usd is null then
      new.service_price_usd := public.service_price_now(new.brand, new.service_id);
    end if;
    if new.total_usd is null and new.service_price_usd is not null then
      new.total_usd := new.service_price_usd + case when coalesce(new.at_home, false) then coalesce(new.home_fee_usd, 0) else 0 end;
    end if;
    return new;
  end if;

  new.status := 'Requested';
  new.reminders := '{}'::jsonb;
  new.price_log := '[]'::jsonb;
  -- The price comes from the price list, never from the phone.
  price := public.service_price_now(new.brand, new.service_id);
  new.service_price_usd := price;

  if coalesce(new.at_home, false) then
    begin
      select value::jsonb into cfg from public.settings where key = 'home_service';
    exception when others then cfg := null; end;
    bcfg := cfg -> 'brands' -> new.brand;
    if new.brand = 'core' or bcfg is null or coalesce((bcfg->>'enabled')::boolean, false) is not true
       or not exists (select 1 from public.services s
                       where s.id = new.service_id and s.brand = new.brand and s.home_ok) then
      raise exception 'HOME_NOT_AVAILABLE' using errcode = '23514',
        hint = 'Home visits are not offered for this service.';
    end if;
    select x.value into area from jsonb_array_elements(coalesce(bcfg->'areas', '[]'::jsonb)) as x(value)
     where x.value->>'id' = new.home_area_id and coalesce((x.value->>'active')::boolean, true)
     limit 1;
    if area is null then
      raise exception 'HOME_AREA_NOT_COVERED' using errcode = '23514',
        hint = 'That area is not on the list — contact reception for a quote.';
    end if;
    new.home_area    := left(area->>'name', 80);
    new.home_address := left(btrim(coalesce(new.home_address, '')), 300);
    if length(new.home_address) < 6 then
      raise exception 'HOME_ADDRESS_REQUIRED' using errcode = '23514',
        hint = 'A home visit needs an address.';
    end if;
    -- The saved home-service price (Admin → Home Services), exactly as entered:
    -- no discount and no fallback to the clinic / salon price. None saved → refused.
    select s.home_price_usd into price from public.services s
     where s.id = new.service_id and s.brand = new.brand and s.home_ok limit 1;
    if price is null then
      raise exception 'HOME_NOT_AVAILABLE' using errcode = '23514',
        hint = 'This service has no home-service price yet.';
    end if;
    new.service_price_usd := price;
    new.home_fee_usd := greatest(0, coalesce((area->>'fee')::numeric, 0));   -- travel fee, once
    new.total_usd := coalesce(price, 0) + new.home_fee_usd;
  else
    new.at_home := false; new.home_area_id := ''; new.home_area := ''; new.home_address := ''; new.home_fee_usd := 0;
    new.total_usd := price;
  end if;

  if coalesce(new.time_label, '') = '' then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || coalesce(new.brand, '') || ':' ||
           coalesce(new.date_iso::text, new.date_label, '') || ':' || new.time_label));
  if exists (
    select 1 from public.bookings b
     where b.id <> new.id
       and b.brand = new.brand
       and b.status not in ('Cancelled', 'No-show')
       and (b.time_label = new.time_label or (new.time_of_day is not null and b.time_of_day = new.time_of_day))
       and (case when new.date_iso is not null and b.date_iso is not null
                 then b.date_iso = new.date_iso
                 else b.date_label = new.date_label end)
  ) then
    raise exception 'SLOT_TAKEN' using errcode = '23P01',
      hint = 'That time was just booked by someone else.';
  end if;
  return new;
end; $$;

commit;

-- Check (should list 1 row):
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'services' and column_name = 'home_price_usd';
