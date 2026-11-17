-- ============================================================================
--  Dolce+ — "BOOKING CONFIRMED" MESSAGE + iPhone notifications
--  (run once in Supabase → SQL Editor; safe to run again)
--
--  Adds a fourth automatic message: when reception confirms a booking (or
--  adds one as Confirmed), the client gets "Your appointment at … is
--  confirmed ✅ — date at time". It goes out the same way as the reminders
--  (iPhone app notification, chosen in Admin → Settings → Automatic messages).
--  The owner can switch it off there ("Tell the client when a booking is
--  confirmed").
--
--  Changes no bookings, clients or points. Nothing is sent until automatic
--  messages are switched on in Admin. All or nothing.
-- ============================================================================
begin;

-- 1. Allow the new kind of message.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.notifications'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%kind%' loop
    execute format('alter table public.notifications drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('cancel', 'moved', 'reminder', 'confirmed'));

-- 2. The booking trigger: same as before, plus the confirmation message.
create or replace function public.booking_notifications()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg jsonb; moves int;
begin
  -- Reminders always stop when a booking is no longer going ahead, even if
  -- automatic messages were switched off in the meantime.
  if tg_op = 'UPDATE' and (new.status in ('Cancelled', 'Completed', 'No-show')
                           or new.start_at is distinct from old.start_at) then
    perform public.cancel_reminders('booking', new.id,
      case when new.status = 'Cancelled' then 'booking cancelled'
           when new.status in ('Completed', 'No-show') then 'booking ' || lower(new.status)
           else 'booking moved' end);
  end if;
  if not public.notif_on() then return null; end if;
  cfg := public.notif_cfg();

  -- Cancellation message.
  if tg_op = 'UPDATE' and new.status = 'Cancelled' and old.status in ('Requested', 'Confirmed')
     and coalesce((cfg->>'cancel')::boolean, true) then
    perform public.queue_notification('booking', new.id, new.brand, 'cancel', null, now(),
      public.booking_phone(new), new.client_id::text, new.lang, public.booking_payload(old),
      'cancel:booking:' || new.id || ':' || coalesce(extract(epoch from old.start_at)::bigint::text, old.date_label || old.time_label));
    return null;
  end if;

  -- NEW: booking confirmed (Requested → Confirmed, or added as Confirmed),
  -- only for an appointment still ahead. One message per booking and time.
  if new.status = 'Confirmed' and (tg_op = 'INSERT' or old.status is distinct from 'Confirmed')
     and new.start_at is not null and new.start_at > now()
     and coalesce((cfg->>'confirmed')::boolean, true) then
    perform public.queue_notification('booking', new.id, new.brand, 'confirmed', null, now(),
      public.booking_phone(new), new.client_id::text, new.lang, public.booking_payload(new),
      'confirmed:booking:' || new.id || ':' || extract(epoch from new.start_at)::bigint);
  end if;

  -- New time for a confirmed appointment.
  if tg_op = 'UPDATE' and new.status = 'Confirmed' and old.status = 'Confirmed'
     and old.start_at is not null and new.start_at is not null
     and new.start_at <> old.start_at and new.start_at > now() and coalesce((cfg->>'moved')::boolean, true) then
    moves := jsonb_array_length(coalesce(new.reschedule_log, '[]'::jsonb));
    perform public.queue_notification('booking', new.id, new.brand, 'moved', null, now(),
      public.booking_phone(new), new.client_id::text, new.lang,
      public.booking_payload(new) || jsonb_build_object('old_date', old.date_label, 'old_time', old.time_label),
      'moved:booking:' || new.id || ':' || extract(epoch from new.start_at)::bigint || ':' || moves);
  end if;

  if new.status = 'Confirmed' then perform public.schedule_booking_reminders(new); end if;
  return null;
end; $$;

drop trigger if exists bookings_notifications on public.bookings;
create trigger bookings_notifications after insert or update on public.bookings
  for each row execute function public.booking_notifications();

commit;

-- Check (one row): both true.
select
  exists (select 1 from pg_constraint where conname = 'notifications_kind_check'
            and pg_get_constraintdef(oid) ilike '%confirmed%') as confirmed_kind,
  exists (select 1 from pg_trigger where tgname = 'bookings_notifications') as booking_trigger;
