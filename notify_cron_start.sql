-- ============================================================================
--  Dolce+ — START THE AUTOMATIC SENDING (easy version, nothing to edit)
--  Run in Supabase → SQL Editor. Safe to run again (it makes a new secret).
--
--  1. Makes a new random secret and keeps it in the database Vault (encrypted).
--  2. Every 2 minutes: asks the notify-dispatch function to send what is due.
--  3. Shows the secret ONCE in the result → copy it into
--     Edge Functions → Secrets → NOTIFY_CRON_SECRET (Edit → paste → Save).
--     Do not send it to anyone, not in chat either.
-- ============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
declare v text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if exists (select 1 from vault.secrets where name = 'notify_cron_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'notify_cron_secret'), v);
  else
    perform vault.create_secret(v, 'notify_cron_secret', 'Dolce+ notify-dispatch caller secret');
  end if;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'dolce-notify-dispatch';
select cron.schedule('dolce-notify-dispatch', '*/2 * * * *', $job$
  select net.http_post(
    url     := 'https://rljfpxxgtuujcdxvcuow.supabase.co/functions/v1/notify-dispatch',
    headers := jsonb_build_object('Content-Type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000);
$job$);

-- Result (one row): copy "secret_for_supabase" into NOTIFY_CRON_SECRET.
select (select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_secret') as secret_for_supabase,
       (select active from cron.job where jobname = 'dolce-notify-dispatch') as sending_schedule_active;
