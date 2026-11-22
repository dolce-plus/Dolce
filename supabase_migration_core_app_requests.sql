-- ============================================================================
--  CORE packages & sessions: requested in the app, time set by CORE
--  Run once in Supabase → SQL Editor. Safe to run again.
--
--  Clients can now send a request for a CORE package or private/duet session
--  from the app WITHOUT choosing a time. It arrives in Admin → Bookings under
--  "CORE · waiting for a time"; CORE's staff press "Set time", which saves the
--  date and time and confirms the booking.
--
--  The database already accepts a request without a time. This adds one thing:
--  bookings.client_note — the client's "When suits you?" answer (optional,
--  max 200 characters, trimmed by the server).
-- ============================================================================

alter table public.bookings add column if not exists client_note text not null default '';

create or replace function public.booking_client_note_tidy()
returns trigger language plpgsql as $$
begin
  new.client_note := left(btrim(regexp_replace(coalesce(new.client_note, ''), '\s+', ' ', 'g')), 200);
  return new;
end; $$;

drop trigger if exists booking_client_note_tidy on public.bookings;
create trigger booking_client_note_tidy before insert or update of client_note on public.bookings
  for each row execute function public.booking_client_note_tidy();

-- Check: one row that says "ok"
select case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'bookings' and column_name = 'client_note')
            then 'ok' else 'missing' end as core_app_requests;
