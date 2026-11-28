-- ============================================================================
--  Dolce+ — RESCHEDULE: only the SAME service can block a time
--  Run once in Supabase → SQL Editor. Safe to run again. Changes no bookings.
--
--  Before: moving a booking warned "X is booked at 4:00 PM" for ANY service of
--  that brand (each brand counted as one diary). Now it matches the client
--  booking rule (supabase_migration_service_capacity.sql): only bookings of the
--  same service count, and only when all its staff (staff_count) are busy.
--  Needs supabase_migration_service_capacity.sql first (staff_count).
-- ============================================================================
begin;

create or replace function public.staff_reschedule_booking(p_id text, p_date date, p_time text, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; t time; st timestamptz; en timestamptz; dur int; step int;
        hrs jsonb; dh jsonb; o time; c time; problems jsonb := '[]'::jsonb; x record; who text;
        cap int; same jsonb := '[]'::jsonb;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not (public.is_staff() and public.can_write('bookings', b.brand)) then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if b.status not in ('Requested', 'Confirmed') then raise exception 'BAD_STATUS' using errcode = 'P0001'; end if;
  begin
    t := case when upper(btrim(p_time)) ~ '(AM|PM)$' then to_timestamp(upper(btrim(p_time)), 'HH12:MI AM')::time
              else btrim(p_time)::time end;
  exception when others then raise exception 'BAD_TIME' using errcode = '22023'; end;
  st := (p_date + t) at time zone 'Asia/Baghdad';
  if st <= now() then raise exception 'IN_PAST' using errcode = 'P0001'; end if;
  if st = b.start_at then raise exception 'SAME_TIME' using errcode = 'P0001'; end if;

  hrs := public.setting_json('hours') -> b.brand;
  step := coalesce(nullif(hrs->>'step', '')::int, 60);
  dur := coalesce(public.duration_minutes((select s.duration from public.services s where s.id = b.service_id)), step);
  en := st + make_interval(mins => dur);

  -- Opening hours (Admin → Overview → Opening hours; default 10:00–18:00).
  if coalesce(hrs->'closed', '[]'::jsonb) ? p_date::text then
    problems := problems || jsonb_build_object('type', 'closed', 'text', 'Closed that day (day off)');
  else
    dh := coalesce(hrs->'days'->(extract(dow from p_date)::int::text), '{}'::jsonb);
    if coalesce((dh->>'off')::boolean, false) then
      problems := problems || jsonb_build_object('type', 'closed', 'text', 'Closed on that weekday');
    else
      o := coalesce(nullif(dh->>'o', ''), '10:00')::time; c := coalesce(nullif(dh->>'c', ''), '18:00')::time;
      if t < o or (p_date + t + make_interval(mins => dur))::time > c or (p_date + t + make_interval(mins => dur))::date > p_date then
        problems := problems || jsonb_build_object('type', 'hours',
          'text', 'Outside opening hours (' || to_char(o, 'FMHH12:MI AM') || '–' || to_char(c, 'FMHH12:MI AM')
                  || '; this service takes ' || dur || ' min)');
      end if;
    end if;
  end if;

  -- Overlapping appointments of the SAME SERVICE only, using its length, and
  -- only when all its staff are busy (Admin → Services → "Staff who can do
  -- this service"). Other services at the same time do not block it — the
  -- same rule the client app uses when booking.
  perform pg_advisory_xact_lock(hashtext('booking-day:' || b.brand || ':' || p_date::text));
  cap := greatest(1, coalesce((select s.staff_count from public.services s where s.id = b.service_id), 1));
  for x in select o2.client_name, o2.time_label, o2.service_name
             from public.bookings o2
            where o2.id <> b.id and o2.brand = b.brand and o2.status in ('Requested', 'Confirmed')
              and o2.service_id is not distinct from b.service_id
              and o2.start_at is not null and o2.date_iso = p_date
              and o2.start_at < en
              and o2.start_at + make_interval(mins => dur) > st loop
    same := same || jsonb_build_object('type', 'overlap',
      'text', coalesce(nullif(x.client_name, ''), 'Another client') || ' is booked at ' || x.time_label || ' (' || coalesce(x.service_name, '') || ')');
  end loop;
  if jsonb_array_length(same) >= cap then problems := problems || same; end if;

  if jsonb_array_length(problems) > 0 and not coalesce(p_force, false) then
    return jsonb_build_object('ok', false, 'problems', problems, 'duration', dur);
  end if;

  who := coalesce((select name from public.profiles where id = auth.uid()), 'staff');
  update public.bookings set
         date_iso = p_date, date_label = to_char(p_date, 'Mon FMDD, YYYY'), time_label = to_char(t, 'FMHH12:MI AM'),
         reminders = '{}'::jsonb,
         reschedule_log = coalesce(reschedule_log, '[]'::jsonb) || jsonb_build_object(
           'at', now(), 'by', who, 'by_id', auth.uid(),
           'from', jsonb_build_object('date', b.date_label, 'time', b.time_label),
           'to', jsonb_build_object('date', to_char(p_date, 'Mon FMDD, YYYY'), 'time', to_char(t, 'FMHH12:MI AM')),
           'forced', (jsonb_array_length(problems) > 0), 'problems', problems)
   where id = b.id;
  select * into b from public.bookings where id = p_id;
  return jsonb_build_object('ok', true, 'problems', problems, 'duration', dur,
    'date', b.date_label, 'time', b.time_label, 'date_iso', b.date_iso, 'log', b.reschedule_log);
end; $$;
revoke all on function public.staff_reschedule_booking(text, date, text, boolean) from public;
grant execute on function public.staff_reschedule_booking(text, date, text, boolean) to authenticated;

commit;

-- Check (should say: ok)
select case when prosrc like '%staff_count%' then 'ok' else 'not updated' end as reschedule_same_service
  from pg_proc where proname = 'staff_reschedule_booking';
