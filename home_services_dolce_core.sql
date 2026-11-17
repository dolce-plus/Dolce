-- ============================================================================
--  Dolce+ — Home Services prices for DOLCE and CORE (run once in SQL Editor)
--  Safe to run again. Changes ONLY the home-service fields (home_ok,
--  home_price_usd, home_price_from). Clinic/studio prices, bookings, clients
--  and points are not touched. All or nothing.
--
--  DOLCE (home price = 2 × the clinic price, worked out from the live price):
--    • IV Therapy — all drips (incl. the 4-session drip packages)
--    • Booster shots (incl. the booster-shot packages)
--    • Massages (all 9)
--    • Express Facial
--  CORE (fixed home prices, on the matching private-session services):
--    • Pilates  1 = $100 · 5 = $450 · 10 = $750
--    • Yoga     1 = $80  · 5 = $380 · 10 = $700
-- ============================================================================
begin;

update public.services
   set home_ok = true, home_price_usd = round(price_usd * 2, 2), home_price_from = false
 where brand = 'dolce' and id in (
  -- IV Therapy drips
  'svc_dolce_mujsume63a23eff2','svc_dolce_mujvvxq92a38d5fa','svc_dolce_mujw2sd4361d0d32',
  'svc_dolce_mujw98vqc21035bd','svc_dolce_mujwjp9w0f863ba7','svc_dolce_mujxf18n2f0a2462',
  'svc_dolce_mujyh0hqa5be35e6','svc_dolce_mujysog3fc8a3296','svc_dolce_mutykpkw8f4b13b0',
  'svc_dolce_mutyw6ee49a4371e','svc_dolce_mutqrnyqa6707891','svc_dolce_mutqxkhf24239b15',
  -- Booster shots
  'svc_dolce_mujz9h8w06c5cfa8','svc_dolce_muk1pa54b849aa80','svc_dolce_mutp9x6l4c3cbc59',
  'svc_dolce_mutr12sne26b80bf','svc_dolce_mutr2sxf6325d324','svc_dolce_mutr6ba9b0db6a62',
  -- Massages
  'svc_dolce_muzla5ps3222b7cf','svc_dolce_muzlkxuof87611f4','svc_dolce_muzlo0m89824f8e0',
  'svc_dolce_mv3r08qu48d1aa4c','svc_dolce_mv3r1ywu689dc7a7','svc_dolce_mv3r89uub4fbe8ad',
  'svc_dolce_mv3rdvl3b84985c8','svc_dolce_mv3rlbzmc26f06ac','svc_dolce_mv3rnvet4d3d4a6a',
  -- Express Facial
  'svc_dolce_mv9k8oec667dc1bf');

update public.services s
   set home_ok = true, home_price_usd = v.p, home_price_from = false
  from (values
    ('svc_core_muibfezoc1a0c4f0', 100), -- Pilates 1 session
    ('svc_core_muibgv1mc63e2223', 450), -- Pilates 5 sessions
    ('svc_core_muibib1aa87df37a', 750), -- Pilates 10 sessions
    ('svc_core_muic2uyycaf0d544',  80), -- Yoga 1 session
    ('svc_core_muic41da6e63eb2d', 380), -- Yoga 5 sessions
    ('svc_core_muic54see33ea9f1', 700)  -- Yoga 10 sessions
  ) as v(id, p)
 where s.brand = 'core' and s.id = v.id;

commit;

-- Check (one row): dolce_home = 28, core_home = 6
select count(*) filter (where brand='dolce' and home_ok and home_price_usd is not null) as dolce_home,
       count(*) filter (where brand='core'  and home_ok and home_price_usd is not null) as core_home
  from public.services;
