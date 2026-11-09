-- ===== User accounts, step 2: retire the shared profiles =====
-- Run this only once EVERY device (PCs, phones, browsers) has the app with
-- username sign-in. After it, the old Admin / Admin team / Director / Team
-- profiles and the old admin password stop working; everyone signs in with
-- their own account.

-- Sign out every old shared-profile device.
delete from private.admin_tokens where user_id is null;

-- The old sign-ins now refuse, with a code older apps show as an error.
create or replace function public.admin_login(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'use_accounts' using errcode = '42501';
end $$;

create or replace function public.admin_claim(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'use_accounts' using errcode = '42501';
end $$;

create or replace function public.admin_recover(p_code text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'use_accounts' using errcode = '42501';
end $$;

create or replace function public.profile_login(p_role text, p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'use_accounts' using errcode = '42501';
end $$;

-- Every token must now belong to an active account.
create or replace function private.token_role(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text;
begin
  select t.role into r
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active
    where t.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and t.expires_at > now();
  if r is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  return r;
end $$;

-- The old passwords are no longer needed.
update private.admin_secret set recovery_hash = null;
update private.profile_secret set hash = null;

revoke all on all functions in schema private from public, anon, authenticated;
