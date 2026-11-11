-- ============================================================================
--  POLISHED — home-service prices (from the owner's list, 12 Nov 2026)
--  Run once in Supabase → SQL Editor. Changes ONLY the home-service price,
--  the "from" flag and Offered on these Polished services. Salon prices,
--  names and bookings are not touched. Home visits stay OFF (the switch in
--  Settings → Home visits is not changed).
--  All or nothing: if any line fails, nothing is saved.
-- ============================================================================
begin;

update public.services s set home_ok = true, home_price_usd = v.price, home_price_from = v.from_price
  from (values
    -- Nails (fixed prices)
    ('svc_polished_mujr0p1maa7dcdca',  70::numeric, false),  -- Gel Manicure
    ('svc_polished_mujq97roe016407d', 100,          false),  -- Gel Pedicure
    ('svc_polished_mufojrsib58c4fa1',  50,          false),  -- Classic Manicure
    ('svc_polished_mujpq69660bee569',  60,          false),  -- Classic Pedicure
    ('svc_polished_mujodg0g70527fd3', 140,          false),  -- Gel Extension Manicure
    ('svc_polished_mujpaf3e3ff161e2', 110,          false),  -- Gel Extension Refill
    ('svc_polished_mujszp491d53673f', 150,          false),  -- Medical Pedicure
    ('svc_polished_muk0d5kg09288b4d',  60,          false),  -- Classic Manicure (Men)
    ('svc_polished_muk0mzxk93bc1a6d', 100,          false),  -- Classic Pedicure (Men)
    -- Hair
    ('svc_polished_mvdm8dn8481671f3',  60,          true ),  -- Cut + Wash + Blowdry  (from $60; owner: $60–90)
    ('svc_polished_mvdyextd05fa53b5', 120,          true ),  -- Full Hair Color       (from $120; owner: $120–140)
    ('svc_polished_mvdyquxle4ca6a0c', 300,          true ),  -- Highlights and Ombre hair (from $300)
    ('svc_polished_mvdyyxhd326fc1c4', 300,          true ),  -- Keratin Smoothing Treatment (from $300)
    ('svc_polished_mv9on9xjb3fe3681',  20,          false),  -- BlowDry - no wash
    ('svc_polished_mv9oiiq850bb713a',  30,          false),  -- Blow dry + wash
    ('svc_polished_mvdmfkzq1a99dcbf',  60,          true ),  -- Simple Hair Style     (from $60)
    -- Lashes & Brows
    ('svc_polished_mumky76hc992c02c', 100,          false),  -- Lash Lifting
    ('svc_polished_mumksygrac654cab', 120,          false),  -- Brow Lifting
    ('svc_polished_mumnqbkv69695b0c',  40,          false),  -- Lash Tint
    ('svc_polished_mumnwyi7ddce69af',  60,          false)   -- Brow Tint
  ) as v(id, price, from_price)
 where s.id = v.id and s.brand = 'polished';

-- Stop (and save nothing) unless exactly these 20 Polished services were updated.
do $$ begin
  if (select count(*) from public.services where brand = 'polished' and home_ok and home_price_usd is not null) < 20 then
    raise exception 'Not all 20 services were found — nothing saved. Send Claude a screenshot.';
  end if;
end $$;

commit;

-- Check: the Polished home services (should be 20 rows)
select name, category, price_usd as salon_price,
       case when home_price_from then 'from ' else '' end || '$' || home_price_usd as home_price
  from public.services
 where brand = 'polished' and home_ok
 order by category, name;
