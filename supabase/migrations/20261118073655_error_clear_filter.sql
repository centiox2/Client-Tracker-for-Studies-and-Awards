-- Settings > About > Problems reported > Clear must work while pg-safeupdate
-- requires a WHERE clause. Only the admin-authorized error log is affected.
-- Applying this migration replaces the function; it does not clear any logs.
begin;

create or replace function public.error_clear(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if private.token_role(p_token) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from private.error_reports where id is not null;
end $$;

revoke all on function public.error_clear(text) from public;
grant execute on function public.error_clear(text) to anon, authenticated;

commit;
