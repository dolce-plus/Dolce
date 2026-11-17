-- Dolce+ Wallet card — switch on the daily level check (run once in SQL Editor).
-- Turns on Supabase's built-in scheduler (pg_cron) and runs the card level
-- check every night at 03:15 Erbil time. It changes no points or clients.

create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'wallet-daily-levels';
select cron.schedule('wallet-daily-levels', '15 0 * * *', 'select public.wallet_refresh_all()');

-- Check (one row): daily_check = true
select exists (select 1 from cron.job where jobname = 'wallet-daily-levels') as daily_check;
