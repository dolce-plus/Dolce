-- ============================================================================
--  Dolce+ — STAFF PER SERVICE (several clients at the same time)
--  Run once in Supabase → SQL Editor. Safe to run again. Changes no bookings.
--
--  Admin → Services → "Staff who can do this service" (1–20, default 1).
--  A time can be booked by as many clients as there are staff for THAT
--  service: 3 = three clients can book 11:00, the 4th sees it as taken.
--  Different services no longer block each other at the same time.
--
--   1. services.staff_count
--   2. busy_slots_service(): the times where one service is fully booked
--      (times only — no names or numbers), used by the new app.
--      The old busy_slots() stays as it was for app versions already on phones.
--   3. booking_request_guard: the same as Home Services v5, with the slot check
--      counting bookings of the same service against its staff number.
-- ============================================================================
begin;

alter table public.services add column if not exists staff_count integer not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'services_staff_count_ck') then
    alter table public.services add constraint services_staff_count_ck check (staff_count between 1 and 20);
  end if;
end $$;

create or replace function public.busy_slots_service(p_brand text, p_service text, p_from date, p_to date)
returns table (date_iso date, time_label text)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.date_iso, b.time_label
    from public.bookings b
   where b.brand = p_brand
     and b.service_id = p_service
     and b.status not in ('Cancelled', 'No-show')
     and b.date_iso is not null
     and b.date_iso between p_from and least(p_to, p_from + 62)
     and coalesce(b.time_label, '') <> ''
   group by b.date_iso, b.time_label
  having count(*) >= coalesce((select greatest(1, s.staff_count) from public.services s
                                where s.id = p_service and s.brand = p_brand limit 1), 1);
$$;
revoke all on function public.busy_slots_service(text, text, date, date) from public;
grant execute on function public.busy_slots_service(text, text, date, date) to anon, authenticated;

create or replace function public.booking_request_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cfg jsonb; bcfg jsonb; area jsonb; price numeric; n_areas int; cap int; taken int;
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
  -- One time can be booked as many times as there are staff who can do THIS
  -- service (services.staff_count, Admin → Services). Other services at the
  -- same time no longer block it.
  select greatest(1, coalesce(s.staff_count, 1)) into cap
    from public.services s where s.id = new.service_id and s.brand = new.brand limit 1;
  cap := coalesce(cap, 1);
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || coalesce(new.brand, '') || ':' || coalesce(new.service_id, '') || ':' ||
           coalesce(new.date_iso::text, new.date_label, '') || ':' || new.time_label));
  select count(*) into taken from public.bookings b
   where b.id <> new.id
     and b.brand = new.brand
     and b.service_id = new.service_id
     and b.status not in ('Cancelled', 'No-show')
     and (b.time_label = new.time_label or (new.time_of_day is not null and b.time_of_day = new.time_of_day))
     and (case when new.date_iso is not null and b.date_iso is not null
               then b.date_iso = new.date_iso
               else b.date_label = new.date_label end);
  if taken >= cap then
    raise exception 'SLOT_TAKEN' using errcode = '23P01',
      hint = 'That time was just booked by someone else.';
  end if;
  return new;
end; $$;

commit;

-- Check (should say: ok)
select case when prosrc like '%staff_count%' then 'ok' else 'not updated' end as staff_per_service
  from pg_proc where proname = 'booking_request_guard';
