-- ============================================================================
--  Dolce+ — OPTIONAL EMAIL for clients who log in with WhatsApp
--  Run once in Supabase → SQL Editor. Safe to run again. Changes no data.
--
--  At sign-up (and later in Profile) a client can add an email "for event
--  invitations and offers". It is saved as clients.contact_email — NOT the
--  email used to log in (clients.email), so it can never be used to log in to
--  or take over anyone's account. Staff see it in Admin → Clients.
-- ============================================================================
begin;

alter table public.clients add column if not exists contact_email text;

-- The signed-in client sets (or clears, with '') the contact email on their
-- own record(s) only.
create or replace function public.set_my_contact_email(p_email text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare e text := lower(btrim(coalesce(p_email, '')));
begin
  if auth.uid() is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  if e <> '' and (length(e) > 254 or e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
    raise exception 'BAD_EMAIL' using errcode = '22023';
  end if;
  update public.clients set contact_email = nullif(e, '')
   where id::text = any(public.my_client_ids());
  return nullif(e, '');
end;
$$;
revoke all on function public.set_my_contact_email(text) from public;
grant execute on function public.set_my_contact_email(text) to authenticated;

commit;

-- Check (should say: ok)
select case when exists (select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'clients' and column_name = 'contact_email')
  and exists (select 1 from pg_proc where proname = 'set_my_contact_email')
  then 'ok' else 'not updated' end as contact_email;
