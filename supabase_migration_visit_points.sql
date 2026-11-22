-- ============================================================================
--  Dolce+ — D+ points for visits booked OUTSIDE the app
--  (WhatsApp, Mindbody, walk-ins, phone)   ·   run once in Supabase → SQL Editor
--
--  Admin → Loyalty → "Record a visit": staff pick the client, the business and
--  the amount paid (optionally a Mindbody / receipt number). The app works out
--  the points with the client's level bonus (Gold / Black) — the 1.25× app
--  bonus stays only for bookings made in the Dolce+ app. The amount counts
--  toward the client's level, like any visit.
--
--  What this file does
--   1. point_transactions.visit_ref — a reference for such a visit. The same
--      reference can earn points only once (a receipt number can't be used
--      twice, and a double tap can't add points twice).
--   2. pt_check_earn: an "earn" line now needs ONE source — a completed
--      booking, a completed + paid shop order, or a visit reference with an
--      amount paid and a business. A visit line can't carry more than 5 points
--      per dollar (a safety net against typing mistakes).
--  Who may add points is unchanged (pt_staff_add: owner, or staff with the
--  Loyalty or Bookings section, for their own businesses).
--  Safe to run more than once. Changes no existing data.
-- ============================================================================

alter table public.point_transactions add column if not exists visit_ref text;

create unique index if not exists pt_one_earn_per_visit
  on public.point_transactions (visit_ref)
  where kind = 'earn' and visit_ref is not null;

create or replace function public.pt_check_earn()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  j   jsonb := to_jsonb(new);           -- read optional columns safely
  oid text  := j->>'order_id';
begin
  if new.kind <> 'earn' then return new; end if;

  -- A visit booked outside the app (WhatsApp, Mindbody, walk-in)
  if new.visit_ref is not null then
    if btrim(new.visit_ref) = '' then
      raise exception 'VISIT_NEEDS_REF' using errcode = 'P0001';
    end if;
    if new.booking_id is not null or oid is not null then
      raise exception 'VISIT_ONE_SOURCE' using errcode = 'P0001',
        hint = 'A visit line cannot also point to a booking or an order.';
    end if;
    if coalesce(new.spend, 0) <= 0 then
      raise exception 'VISIT_NEEDS_AMOUNT' using errcode = 'P0001',
        hint = 'Type the amount the client paid.';
    end if;
    if coalesce(new.brand, '') not in ('dolce', 'polished', 'core') then
      raise exception 'VISIT_NEEDS_BRAND' using errcode = 'P0001';
    end if;
    if new.points > ceil(new.spend * 5) then
      raise exception 'VISIT_TOO_MANY_POINTS' using errcode = 'P0001',
        hint = 'More than 5 points per dollar — check the amount.';
    end if;
    return new;
  end if;

  -- A shop order: only when completed and paid
  if oid is not null then
    if to_regclass('public.orders') is null then
      raise exception 'NOT_COMPLETED_PAID' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.orders o where o.id::text = oid and o.status = 'Completed' and o.paid) then
      raise exception 'NOT_COMPLETED_PAID' using errcode = 'P0001', hint = 'Points are added only after the order is completed and paid.';
    end if;
    return new;
  end if;

  -- A booking made in the app or by reception: only when Completed
  if new.booking_id is not null then
    if not exists (select 1 from public.bookings b where b.id::text = new.booking_id and b.status = 'Completed') then
      raise exception 'NOT_COMPLETED' using errcode = 'P0001', hint = 'Points are added only after the visit is marked Completed.';
    end if;
    return new;
  end if;

  raise exception 'EARN_NEEDS_SOURCE' using errcode = 'P0001';
end; $$;

drop trigger if exists pt_check_earn on public.point_transactions;
create trigger pt_check_earn before insert on public.point_transactions
  for each row execute function public.pt_check_earn();

-- Check (should list the new column and index):
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'point_transactions' and column_name = 'visit_ref';
