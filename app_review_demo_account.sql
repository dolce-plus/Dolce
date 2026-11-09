-- ============================================================================
--  APP REVIEW DEMO ACCOUNT  (run once in Supabase → SQL Editor)
--
--  Apple's reviewer cannot receive our WhatsApp or email login codes, so they
--  get a demo client with a FIXED test number and code:
--
--     Phone:  +964 750 000 0001        Code: set in Supabase (see below)
--
--  STEP 1 (Supabase dashboard, not SQL): Authentication → Sign In / Providers
--          → Phone → "Test Phone Numbers and OTPs":   9647500000001=<6-digit code>
--          (and set the expiry date a few months ahead). Supabase then accepts
--          that code for that number and sends nothing to WhatsApp.
--  STEP 2: run this file. It makes the demo client (linked automatically the
--          first time the reviewer logs in with that number), with D+ points
--          and one upcoming appointment so every screen has content.
--
--  Everything is labelled "App Review (Demo)". Remove it after approval with
--  the block at the bottom.
-- ============================================================================

do $$
declare
  svc record;
  d   date := current_date + 45;      -- far ahead: blocks one slot only, weeks away
begin
  if exists (select 1 from public.clients
              where right(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 10) = '7500000001'
                and id::text <> 'a0000000-0000-4000-8000-0000000000a1') then
    raise exception 'Another client already uses a number ending 750 000 0001 — choose a different demo number.';
  end if;

  insert into public.clients (id, phone, name, points)
  values ('a0000000-0000-4000-8000-0000000000a1', '9647500000001', 'App Review (Demo)', 0)
  on conflict (id) do nothing;

  -- Points history (the points total follows automatically).
  if not exists (select 1 from public.point_transactions where client_id = 'a0000000-0000-4000-8000-0000000000a1') then
    insert into public.point_transactions (client_id, kind, points, spend, brand, reason, staff_name)
    values ('a0000000-0000-4000-8000-0000000000a1', 'opening', 185, 0, '', 'App Review demo — welcome points', 'Demo');   -- 'earn' needs a real visit
  end if;

  -- One upcoming, confirmed appointment at Polished.
  select id, name into svc from public.services where brand = 'polished' order by sort_order nulls last, name limit 1;
  if svc.id is not null and not exists (select 1 from public.bookings where id = 'app-review-demo-1') then
    insert into public.bookings (id, brand, service_id, service_name, date_label, time_label, date_iso, status,
                                 client_name, client_id, client_phone, aftercare_ok, lang, source)
    values ('app-review-demo-1', 'polished', svc.id, svc.name,
            to_char(d, 'Mon FMDD, YYYY'), '11:00 AM', d, 'Confirmed',
            'App Review (Demo)', 'a0000000-0000-4000-8000-0000000000a1', '9647500000001', true, 'en', 'admin');
  end if;
end $$;

-- Check:
select id, name, phone, points from public.clients where id::text = 'a0000000-0000-4000-8000-0000000000a1';
select id, service_name, date_label, time_label, status from public.bookings where client_id::text = 'a0000000-0000-4000-8000-0000000000a1';

-- ---------------------------------------------------------------------------
-- AFTER APPROVAL — remove the demo data (select these lines and run them):
-- delete from public.bookings where client_id = 'a0000000-0000-4000-8000-0000000000a1';
-- delete from public.point_transactions where client_id = 'a0000000-0000-4000-8000-0000000000a1';
-- delete from auth.users where id = (select user_id from public.clients where id::text = 'a0000000-0000-4000-8000-0000000000a1');
-- delete from public.clients where id::text = 'a0000000-0000-4000-8000-0000000000a1';
-- …and delete the test number in Authentication → Providers → Phone.
