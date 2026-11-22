-- ============================================================================
--  Hide the staff list from visitors
--  Run once in Supabase → SQL Editor, AFTER the new staff-auth function is
--  deployed and the app update is pushed. Safe to run again.
--
--  Staff now type their own name and PIN. The list of staff names is no
--  longer needed before sign-in, so visitors (and clients) can't read it.
--  Signed-in staff still get it (Employees tab).
-- ============================================================================

create or replace function public.list_staff_names()
returns table (id uuid, name text, login_slug text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.id, p.name, p.login_slug
  from public.profiles p
  where p.login_slug is not null
    and public.is_staff()
  order by p.name;
$$;
revoke all on function public.list_staff_names() from public, anon;
grant execute on function public.list_staff_names() to authenticated;

-- Check: one row that says "ok" (visitors can no longer run it)
select case when has_function_privilege('anon', 'public.list_staff_names()', 'execute')
            then 'still open' else 'ok' end as staff_names_hidden;
