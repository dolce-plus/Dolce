-- ============================================================================
--  HOME VISITS v2 — fees by AREA and business, prices saved with the booking,
--  price changes only before confirmation (with the client's agreement),
--  refund limit.            Run once in Supabase → SQL Editor, AFTER
--  supabase_migration_home_service.sql. Safe to run more than once.
--  Home visits stay OFF (nothing here switches them on).
-- ============================================================================

begin;   -- all or nothing: an error anywhere below changes nothing

-- ---- 1. New columns --------------------------------------------------------
alter table public.bookings add column if not exists home_area_id      text          not null default '';
alter table public.bookings add column if not exists service_price_usd numeric(10,2);          -- saved when requested
alter table public.bookings add column if not exists total_usd         numeric(10,2);          -- service + home fee
alter table public.bookings add column if not exists price_log         jsonb         not null default '[]'::jsonb;

-- ---- 2. Settings in the new shape (still OFF) ------------------------------
--  {"version":2,"brands":{"dolce":{"enabled":false,"areas":[{"id","name","name_ar","name_ku","fee","active"}]},...}}
insert into public.settings (key, value)
values ('home_service', '{"version":2,"brands":{"dolce":{"enabled":false,"areas":[]},"polished":{"enabled":false,"areas":[]},"core":{"enabled":false,"areas":[]}}}')
on conflict (key) do nothing;
update public.settings
   set value = '{"version":2,"brands":{"dolce":{"enabled":false,"areas":[]},"polished":{"enabled":false,"areas":[]},"core":{"enabled":false,"areas":[]}}}'
 where key = 'home_service' and value::text not like '%version%2%';

-- Reads a settings row as JSON, however it is stored: a text column, a JSON
-- column, or JSON saved as a quoted string by the app. Unreadable → null.
create or replace function public.home_setting_json(p_key text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t text; j jsonb;
begin
  select value::text into t from public.settings where key = p_key;
  if t is null then return null; end if;
  begin j := t::jsonb; exception when others then return null; end;
  if jsonb_typeof(j) = 'string' then
    begin j := (j #>> '{}')::jsonb; exception when others then return null; end;
  end if;
  return j;
end; $$;

-- ---- 3. A service's price today (after its own discount), as the app shows it
create or replace function public.service_price_now(p_brand text, p_service_id text)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(s.discount_percent, 0) > 0
              then round(s.price_usd * (1 - s.discount_percent / 100.0))
              else s.price_usd end
    from public.services s
   where s.id = p_service_id and s.brand = p_brand
   limit 1;
$$;

-- ---- 4. Booking guard: client requests --------------------------------------
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
      cfg := public.home_setting_json('home_service');
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
    new.home_fee_usd := greatest(0, coalesce((area->>'fee')::numeric, 0));
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

-- ---- 5. Saved prices are locked -------------------------------------------
--  Only staff_change_home_price() (below) may change them, before confirmation.
create or replace function public.booking_price_lock()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.request_role() not in ('anon', 'authenticated') then return new; end if;   -- SQL editor / server
  if coalesce(current_setting('dolce.price_change', true), '') = '1' then return new; end if;
  if old.total_usd is not null and (
       new.service_price_usd is distinct from old.service_price_usd
    or new.home_fee_usd      is distinct from old.home_fee_usd
    or new.total_usd         is distinct from old.total_usd
    or new.home_area_id      is distinct from old.home_area_id
    or new.price_log         is distinct from old.price_log) then
    raise exception 'PRICE_LOCKED' using errcode = '42501',
      hint = 'Saved prices can only change with the client''s agreement, before confirmation.';
  end if;
  return new;
end; $$;
drop trigger if exists bookings_price_lock on public.bookings;
create trigger bookings_price_lock before update on public.bookings
  for each row execute function public.booking_price_lock();

-- ---- 6. Staff: change a home visit's price (client agreed, not yet confirmed)
create or replace function public.staff_change_home_price(p_id text, p_service_price numeric, p_home_fee numeric,
                                                          p_client_agreed boolean, p_note text)
returns setof public.bookings language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; who text;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('bookings', b.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if not coalesce(b.at_home, false) then raise exception 'NOT_HOME_VISIT' using errcode = 'P0001'; end if;
  if b.status <> 'Requested' then raise exception 'NOT_REQUESTED' using errcode = 'P0001',
    hint = 'The price can only change before the visit is confirmed.'; end if;
  if p_client_agreed is not true or length(btrim(coalesce(p_note, ''))) = 0 then
    raise exception 'CLIENT_AGREEMENT_REQUIRED' using errcode = 'P0001'; end if;
  if coalesce(p_service_price, -1) < 0 or coalesce(p_home_fee, -1) < 0 then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001'; end if;
  select coalesce(p.name, '') into who from public.profiles p where p.id = auth.uid();
  perform set_config('dolce.price_change', '1', true);
  update public.bookings
     set service_price_usd = round(p_service_price, 2),
         home_fee_usd      = round(p_home_fee, 2),
         total_usd         = round(p_service_price, 2) + round(p_home_fee, 2),
         price_log = coalesce(price_log, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'at', now(), 'by', coalesce(nullif(who, ''), 'staff'), 'note', left(btrim(p_note), 200), 'client_agreed', true,
           'old', jsonb_build_object('service', b.service_price_usd, 'fee', b.home_fee_usd, 'total', b.total_usd),
           'new', jsonb_build_object('service', round(p_service_price, 2), 'fee', round(p_home_fee, 2),
                                     'total', round(p_service_price, 2) + round(p_home_fee, 2)))),
         updated_at = now()
   where id = p_id;
  perform set_config('dolce.price_change', '', true);
  return query select * from public.bookings where id = p_id;
end; $$;
revoke all on function public.staff_change_home_price(text, numeric, numeric, boolean, text) from public;
grant execute on function public.staff_change_home_price(text, numeric, numeric, boolean, text) to authenticated;

-- ---- 7. Refunds can never exceed what the visit cost ------------------------
--  Limit = the saved total; for older bookings without one, today's price
--  (+ home fee). No price at all → only an owner may refund.
create or replace function public.refund_booking(p_booking_id text, p_refund_id text, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; r jsonb; cap numeric;
begin
  if exists (select 1 from public.booking_refunds where id = p_refund_id) then
    select jsonb_build_object('repeat', true, 'reversed', points_reversed, 'shortfall', points_shortfall)
      into r from public.booking_refunds where id = p_refund_id;
    return r;
  end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('bookings', b.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if b.status <> 'Completed' then raise exception 'NOT_COMPLETED' using errcode = 'P0001'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'BAD_AMOUNT' using errcode = 'P0001'; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'REASON_REQUIRED' using errcode = 'P0001'; end if;
  cap := coalesce(b.total_usd,
                  public.service_price_now(b.brand, b.service_id)
                    + case when coalesce(b.at_home, false) then coalesce(b.home_fee_usd, 0) else 0 end);
  if cap is null then
    if not public.is_owner() then raise exception 'REFUND_NO_PRICE' using errcode = 'P0001'; end if;
  elsif coalesce(b.refunded_usd, 0) + p_amount > cap + 0.004 then
    raise exception 'REFUND_TOO_LARGE' using errcode = 'P0001',
      hint = 'More than what is left to refund for this visit.';
  end if;
  r := public.reverse_points_for_refund('booking', p_booking_id, 'booking-refund:' || p_refund_id, p_amount, p_reason);
  insert into public.booking_refunds (id, booking_id, amount_usd, reason, points_reversed, points_shortfall)
  values (p_refund_id, p_booking_id, p_amount, left(p_reason, 200),
          coalesce((r->>'reversed')::int, 0), coalesce((r->>'shortfall')::int, 0));
  update public.bookings set refunded_usd = refunded_usd + p_amount where id = p_booking_id;
  return r;
end; $$;
revoke all on function public.refund_booking(text, text, numeric, text) from public;
grant execute on function public.refund_booking(text, text, numeric, text) to authenticated;

commit;

-- Check (should list 4 rows):
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'bookings'
   and column_name in ('home_area_id','service_price_usd','total_usd','price_log')
 order by 1;
