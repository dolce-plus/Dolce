-- ============================================================================
--  Dolce+ — APPLE WALLET LOYALTY CARD  (run once in Supabase → SQL Editor)
--
--  What this adds
--   * wallet_cards          one Wallet card per client (serial + member code)
--   * wallet_registrations  which iPhones hold which card (for update pushes)
--   * wallet_log            small technical log (kept 30 days)
--   * The card follows the client's real name, points and level by itself:
--     when points or the name change, the card is refreshed and the "wallet"
--     Edge Function is asked to push the update to the client's iPhone.
--   * A daily check moves cards down a level when the 12-month window passes.
--   * wallet_member_lookup(code): staff scan a card's QR → the client.
--
--  Safety
--   * The three tables are locked: Row Level Security on, no policies, no
--     access for the app's anon/authenticated roles. Only the wallet function
--     (server, service role) and the functions below touch them.
--   * Nothing here changes points, bookings or clients. A failure to reach the
--     wallet function never blocks a points change.
--   * All or nothing: if any part fails, nothing is changed.
-- ============================================================================

begin;

create extension if not exists pg_net with schema extensions;

-- ---- Tables ------------------------------------------------------------------
create table if not exists public.wallet_cards (
  serial       text primary key,
  client_id    text not null unique,
  member_code  text not null unique,           -- 'DP' + 10 characters, shown as DP-XXXXX-XXXXX
  name         text not null default '',
  points       integer not null default 0,
  tier         text not null default 'member' check (tier in ('member','gold','black')),
  member_since date,
  updated_at   timestamptz not null default now(),   -- what the card shows last changed
  pushed_at    timestamptz,                           -- last update push sent
  created_at   timestamptz not null default now()
);
create table if not exists public.wallet_registrations (
  device_id    text not null,
  pass_type_id text not null,
  serial       text not null references public.wallet_cards(serial) on delete cascade,
  push_token   text not null,
  created_at   timestamptz not null default now(),
  primary key (device_id, pass_type_id, serial)
);
create index if not exists wallet_reg_serial_idx on public.wallet_registrations (serial);
create table if not exists public.wallet_log (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  kind   text not null,
  detail jsonb
);

alter table public.wallet_cards         enable row level security;
alter table public.wallet_registrations enable row level security;
alter table public.wallet_log           enable row level security;
revoke all on public.wallet_cards, public.wallet_registrations, public.wallet_log from anon, authenticated;
revoke all on sequence public.wallet_log_id_seq from anon, authenticated;

-- ---- Loyalty settings (same rules as the app: settings key 'loyalty') -------
create or replace function public.wallet_loyalty_num(k text, d numeric)
returns numeric language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  select s.value::text::jsonb into v from public.settings s where s.key = 'loyalty';
  if v is null then return d; end if;
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;   -- stored as a JSON string
  return coalesce(nullif(v ->> k, '')::numeric, d);
exception when others then
  return d;
end; $$;

-- Level = what the client spent in the last 12 months (earn minus refunds),
-- never the points balance — exactly like the app (loyaltyFromRows).
create or replace function public.wallet_tier(cid text)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s numeric;
begin
  select coalesce(sum(t.spend), 0) into s
    from public.point_transactions t
   where t.client_id = cid and t.kind in ('earn', 'reverse')
     and t.created_at >= now() - interval '365 days';
  if s >= public.wallet_loyalty_num('black', 3000) then return 'black'; end if;
  if s >= public.wallet_loyalty_num('gold', 1000)  then return 'gold';  end if;
  return 'member';
end; $$;

-- ---- Ask the wallet function to push an update (never blocks) ---------------
create or replace function public.wallet_notify(p_serial text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.wallet_registrations r where r.serial = p_serial) then return; end if;
  perform net.http_post(
    url     := 'https://rljfpxxgtuujcdxvcuow.supabase.co/functions/v1/wallet/notify',
    body    := jsonb_build_object('serial', p_serial),
    headers := '{"Content-Type":"application/json"}'::jsonb);
exception when others then
  null;   -- a push problem must never stop points or a name change
end; $$;

-- ---- Bring one card up to date; returns true if what it shows changed -------
create or replace function public.wallet_refresh(cid text, p_notify boolean default true)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.wallet_cards; n text; p integer; t text;
begin
  select * into c from public.wallet_cards w where w.client_id = cid;
  if not found then return false; end if;
  select coalesce(nullif(btrim(x.name), ''), 'Dolce+ Member'), coalesce(x.points, 0)
    into n, p from public.clients x where x.id::text = cid;
  if not found then
    delete from public.wallet_cards w where w.client_id = cid;   -- client account removed
    return false;
  end if;
  t := public.wallet_tier(cid);
  if c.name is distinct from n or c.points is distinct from p or c.tier is distinct from t then
    update public.wallet_cards w set name = n, points = p, tier = t, updated_at = now()
     where w.client_id = cid;
    if p_notify then perform public.wallet_notify(c.serial); end if;
    return true;
  end if;
  return false;
end; $$;

-- ---- Create (or return) a client's card — called by the wallet function -----
create or replace function public.wallet_issue_card(cid text)
returns public.wallet_cards language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.wallet_cards; alpha constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
        code text; ser text; b bytea; i int; since date;
begin
  select * into r from public.wallet_cards w where w.client_id = cid;
  if found then
    perform public.wallet_refresh(cid, false);
    select * into r from public.wallet_cards w where w.client_id = cid;
    return r;
  end if;
  select x.created_at::date into since from public.clients x where x.id::text = cid;
  if not found then raise exception 'CLIENT_NOT_FOUND'; end if;
  for attempt in 1..5 loop
    b := decode(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 'hex');
    code := 'DP'; ser := 'W';
    for i in 0..9  loop code := code || substr(alpha, (get_byte(b, i) % 32) + 1, 1); end loop;
    for i in 10..25 loop ser := ser || substr(alpha, (get_byte(b, i) % 32) + 1, 1); end loop;
    begin
      insert into public.wallet_cards (serial, client_id, member_code, member_since)
      values (ser, cid, code, since);
      exit;
    exception when unique_violation then
      if exists (select 1 from public.wallet_cards w where w.client_id = cid) then exit; end if;
      if attempt = 5 then raise; end if;
    end;
  end loop;
  perform public.wallet_refresh(cid, false);
  select * into r from public.wallet_cards w where w.client_id = cid;
  return r;
end; $$;

-- ---- Keep cards in step with points and names --------------------------------
create or replace function public.wallet_after_points()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.wallet_refresh(new.client_id);
  return null;
exception when others then
  return null;   -- never block a points change
end; $$;
drop trigger if exists wallet_after_points on public.point_transactions;
create trigger wallet_after_points after insert on public.point_transactions
  for each row execute function public.wallet_after_points();

create or replace function public.wallet_after_client()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then
    delete from public.wallet_cards w where w.client_id = old.id::text;
    return null;
  end if;
  if new.name is distinct from old.name or new.points is distinct from old.points then
    perform public.wallet_refresh(new.id::text);
  end if;
  return null;
exception when others then
  return null;
end; $$;
drop trigger if exists wallet_after_client on public.clients;
create trigger wallet_after_client after update or delete on public.clients
  for each row execute function public.wallet_after_client();

-- ---- Daily: levels drop when old spending passes 12 months -------------------
create or replace function public.wallet_refresh_all()
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare w record; k integer := 0;
begin
  for w in select client_id from public.wallet_cards loop
    if public.wallet_refresh(w.client_id) then k := k + 1; end if;
  end loop;
  delete from public.wallet_log l where l.at < now() - interval '30 days';
  return k;
end; $$;

-- ---- Staff: scan a card → which client ---------------------------------------
-- Needs a staff login with Loyalty or Bookings (or the owner). 'visible' says
-- whether this staff member may open the client's points (same rule as the app).
create or replace function public.wallet_member_lookup(p_code text)
returns table (client_id text, name text, points integer, tier text, visible boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if not coalesce(public.is_staff(), false) then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  if not coalesce(public.is_owner() or public.has_tab('loyalty') or public.has_tab('bookings'), false) then
    raise exception 'NO_ACCESS' using errcode = '42501';
  end if;
  return query
    select w.client_id, w.name, w.points, w.tier, public.staff_can_see_client(w.client_id)
      from public.wallet_cards w where w.member_code = code;
end; $$;

revoke all on function public.wallet_loyalty_num(text, numeric) from public, anon, authenticated;
revoke all on function public.wallet_tier(text)                 from public, anon, authenticated;
revoke all on function public.wallet_notify(text)               from public, anon, authenticated;
revoke all on function public.wallet_refresh(text, boolean)     from public, anon, authenticated;
revoke all on function public.wallet_issue_card(text)           from public, anon, authenticated;
revoke all on function public.wallet_refresh_all()              from public, anon, authenticated;
revoke all on function public.wallet_member_lookup(text)        from public, anon;
grant execute on function public.wallet_issue_card(text)    to service_role;
grant execute on function public.wallet_refresh(text, boolean) to service_role;
grant execute on function public.wallet_member_lookup(text) to authenticated;

-- Daily level check at 03:15 Erbil time (00:15 UTC), if scheduling is available.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'wallet-daily-levels';
    perform cron.schedule('wallet-daily-levels', '15 0 * * *', 'select public.wallet_refresh_all()');
  end if;
end $$;

commit;

-- Check (one row): all should be true / 'yes'.
select
  (select count(*) from pg_class where relname in ('wallet_cards','wallet_registrations','wallet_log') and relrowsecurity) = 3 as tables_locked,
  exists (select 1 from pg_trigger where tgname = 'wallet_after_points') as points_trigger,
  exists (select 1 from pg_trigger where tgname = 'wallet_after_client') as client_trigger,
  exists (select 1 from pg_extension where extname = 'pg_net') as push_link,
  exists (select 1 from pg_extension where extname = 'pg_cron') as daily_check;
