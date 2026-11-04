-- Supabase helper (event trigger function) needs no public execute.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
