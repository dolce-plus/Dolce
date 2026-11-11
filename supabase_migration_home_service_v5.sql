-- ============================================================================
--  HOME SERVICES v5 — the client gives their own area; reception sets the
--  travel fee. Run once, after v4. All or nothing. Home visits stay OFF.
--  If a business has NO covered areas in Settings → Home visits, clients type
--  their area + address, the request is saved at the home-service price with
--  travel fee 0, and reception sets the travel fee in Admin → Bookings
--  ("Change price", client's agreement required) before confirming.
--  Businesses WITH an area list keep working exactly as before.
-- ============================================================================
begin;
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='services' and column_name='home_price_from') then
    raise exception 'Run supabase_migration_home_service_v4.sql first.';
  end if;
end $$;

-- ---- Booking guard (as v3, plus: no area list = client types the area, travel fee 0 until reception sets it)
create or replace function public.booking_request_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cfg jsonb; bcfg jsonb; area jsonb; price numeric; n_areas int;
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
      cfg := public.home_setting_json('home_service');
    exception when others then cfg := null; end;
    bcfg := cfg -> 'brands' -> new.brand;
    if new.brand = 'core' or bcfg is null or coalesce((bcfg->>'enabled')::boolean, false) is not true
       or not exists (select 1 from public.services s
                       where s.id = new.service_id and s.brand = new.brand and s.home_ok) then
      raise exception 'HOME_NOT_AVAILABLE' using errcode = '23514',
        hint = 'Home visits are not offered for this service.';
    end if;
    select count(*) into n_areas from jsonb_array_elements(coalesce(bcfg->'areas', '[]'::jsonb)) as x(value)
     where coalesce((x.value->>'active')::boolean, true);
    if n_areas = 0 then
      -- No area list: the client types their area; reception sets the travel
      -- fee later (staff_change_home_price, with the client's agreement).
      area := null;
      new.home_area_id := '';
      new.home_area := left(btrim(coalesce(new.home_area, '')), 80);
      if new.home_area = '' then
        raise exception 'HOME_ADDRESS_REQUIRED' using errcode = '23514', hint = 'A home visit needs an area.';
      end if;
    else
      select x.value into area from jsonb_array_elements(coalesce(bcfg->'areas', '[]'::jsonb)) as x(value)
       where x.value->>'id' = new.home_area_id and coalesce((x.value->>'active')::boolean, true)
       limit 1;
      if area is null then
        raise exception 'HOME_AREA_NOT_COVERED' using errcode = '23514',
          hint = 'That area is not on the list — contact reception for a quote.';
      end if;
      new.home_area := left(area->>'name', 80);
    end if;
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
    new.home_fee_usd := case when area is null then 0 else greatest(0, coalesce((area->>'fee')::numeric, 0)) end;   -- travel fee, once (0 = reception sets it)
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

-- Check (should say: ok)
select case when prosrc like '%n_areas%' then 'ok' else 'not updated' end as v5 from pg_proc where proname='booking_request_guard';
