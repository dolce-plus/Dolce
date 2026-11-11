-- Read-only: Polished services as they are in the database (changes nothing).
select id, name, category, duration, price_usd, discount_percent
  from public.services
 where brand = 'polished'
 order by category, name;
