-- ============================================================================
--  Dolce+ — clients can ADD their birthday in Profile (once)
--  Run once in Supabase → SQL Editor. Safe to run again. Changes no data.
--
--  New sign-ups already give their date of birth. Older accounts can add it
--  in Profile → "Add your birthday". It can be set only while it is empty, so
--  nobody can change it to get a second birthday gift; to correct a wrong
--  date the client asks reception.
-- ============================================================================
begin;

create or replace function public.set_my_birth_date(p_birth date)
returns date
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare done int;
begin
  if auth.uid() is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  if p_birth is null or p_birth < date '1910-01-01' or p_birth > current_date then
    raise exception 'BAD_BIRTH' using errcode = '22023';
  end if;
  update public.clients set birth_date = p_birth
   where id::text = any(public.my_client_ids()) and birth_date is null;
  get diagnostics done = row_count;
  if done = 0 and exists (select 1 from public.clients where id::text = any(public.my_client_ids()) and birth_date is not null) then
    raise exception 'BIRTH_ALREADY_SET' using errcode = '22023';
  end if;
  return p_birth;
end;
$$;
revoke all on function public.set_my_birth_date(date) from public;
grant execute on function public.set_my_birth_date(date) to authenticated;

commit;

-- Check (should say: ok)
select case when exists (select 1 from pg_proc where proname = 'set_my_birth_date') then 'ok' else 'not updated' end as client_birthday;
