-- ============================================================================
--  HOME VISITS  (run once in Supabase → SQL Editor)
--
--  * services.home_ok          — this service can be done at the client's home
--  * bookings.at_home / home_area / home_address / home_fee_usd
--  * settings 'home_service'   — {"enabled":bool,"fee":{"dolce":n,"polished":n,"core":n}}
--                                 (owner edits it in Admin → Settings → Home visits)
--  * the booking guard now also checks home-visit requests from clients:
--    home visits must be switched on, the service must allow it, an area and
--    an address are required, and the fee is taken from settings (never from
--    the phone).
--
--  Safe to run more than once. Changes nothing for existing bookings.
-- ============================================================================

alter table public.services add column if not exists home_ok boolean not null default false;

alter table public.bookings add column if not exists at_home      boolean       not null default false;
alter table public.bookings add column if not exists home_area    text          not null default '';
alter table public.bookings add column if not exists home_address text          not null default '';
alter table public.bookings add column if not exists home_fee_usd numeric(10,2) not null default 0;

-- Off until the owner switches it on in Admin.
insert into public.settings (key, value)
values ('home_service', '{"enabled":false,"fee":{"dolce":0,"polished":0,"core":0}}')
on conflict (key) do nothing;

-- Same guard as before (supabase_migration_notifications_classes.sql) + home-visit checks.
create or replace function public.booking_request_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cfg jsonb;
begin
  -- Staff, the SQL editor and the server decide for themselves.
  if public.is_staff() or public.request_role() not in ('anon', 'authenticated') then
    return new;
  end if;
  new.status := 'Requested';
  new.reminders := '{}'::jsonb;

  -- ---- Home visit ----
  if coalesce(new.at_home, false) then
    begin
      select value::jsonb into cfg from public.settings where key = 'home_service';
    exception when others then
      cfg := null;
    end;
    if cfg is null or coalesce((cfg->>'enabled')::boolean, false) is not true
       or not exists (select 1 from public.services s
                       where s.id = new.service_id and s.brand = new.brand and s.home_ok) then
      raise exception 'HOME_NOT_AVAILABLE' using errcode = '23514',
        hint = 'Home visits are not offered for this service.';
    end if;
    new.home_area    := left(btrim(coalesce(new.home_area, '')), 80);
    new.home_address := left(btrim(coalesce(new.home_address, '')), 300);
    if new.home_area = '' or length(new.home_address) < 6 then
      raise exception 'HOME_ADDRESS_REQUIRED' using errcode = '23514',
        hint = 'A home visit needs an area and an address.';
    end if;
    new.home_fee_usd := greatest(0, coalesce((cfg->'fee'->>new.brand)::numeric, 0));
  else
    new.at_home := false;
    new.home_area := '';
    new.home_address := '';
    new.home_fee_usd := 0;
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

-- Check (should list 5 rows):
select table_name, column_name from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'services' and column_name = 'home_ok')
     or (table_name = 'bookings' and column_name in ('at_home','home_area','home_address','home_fee_usd')))
 order by 1, 2;
