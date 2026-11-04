-- ===== Profiles (2026-11-04) =====
-- Four profiles: admin (everything), admin_team (enter and edit everything
-- except revenue), director (view everything), team (view everything except
-- revenue). The admin password is private.admin_secret; the other three
-- each have an optional password (null = open, anyone can choose it).

create table if not exists private.profile_secret (
  role text primary key check (role in ('admin_team', 'director', 'team')),
  hash text,
  updated_at timestamptz not null default now()
);
insert into private.profile_secret (role) values ('admin_team'), ('director'), ('team')
  on conflict (role) do nothing;

-- Tokens now say whose they are. Existing ones are the admin's.
alter table private.admin_tokens add column if not exists role text not null default 'admin';

-- Replaces the old no-argument version (same calls keep working).
drop function if exists private.new_token();
create or replace function private.new_token(p_role text default 'admin')
returns text language plpgsql security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from private.admin_tokens where expires_at < now();
  insert into private.admin_tokens (token_hash, role)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), p_role);
  return t;
end $$;

-- Whose token this is; refuses a missing or expired one.
create or replace function private.token_role(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text;
begin
  select role into r from private.admin_tokens
    where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and expires_at > now();
  if r is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  return r;
end $$;

-- Admin-only actions (passwords, recovery codes) need an admin token.
create or replace function private.check_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if private.token_role(p_token) <> 'admin' then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
end $$;

-- Changing the admin password signs out the admin's other devices only.
create or replace function public.admin_set_password(p_token text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  if length(coalesce(p_new, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens
    where role = 'admin'
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- Which profiles have a password: {"admin_team": true, "director": false, ...}.
create or replace function public.profile_status()
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(role, hash is not null), '{}'::jsonb)
  from private.profile_secret;
$$;

-- Opens a profile. Returns a token for the admin team (so their changes
-- reach the other devices), '' for the view-only profiles.
create or replace function public.profile_login(p_role text, p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare h text;
begin
  if p_role not in ('admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  select hash into h from private.profile_secret where role = p_role;
  if h is not null and extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform pg_sleep(0.5);
    raise exception 'wrong_password' using errcode = '28P01';
  end if;
  if p_role = 'admin_team' then
    return private.new_token('admin_team');
  end if;
  return '';
end $$;

-- The admin sets a profile's password, or leaves it open (null or '').
create or replace function public.admin_set_profile_password(
  p_token text, p_role text, p_password text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  if p_role not in ('admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  if coalesce(p_password, '') <> '' and length(p_password) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  update private.profile_secret
    set hash = case when coalesce(p_password, '') = '' then null
                    else extensions.crypt(p_password, extensions.gen_salt('bf', 10)) end,
        updated_at = now()
    where role = p_role;
  -- A new password: the admin team's devices must sign in again.
  delete from private.admin_tokens where role = p_role;
end $$;

-- Sending changes: the admin team may change everything except revenue.
create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id','id'];
  r text := private.token_role(p_token);
  i int;
begin
  if r not in ('admin', 'admin_team') then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if r = 'admin_team' and (
       jsonb_array_length(coalesce(p_payload->'upserts'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(p_payload->'deletes'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(p_payload->'upserts'->'revenue_changes', '[]')) > 0 or
       jsonb_array_length(coalesce(p_payload->'deletes'->'revenue_changes', '[]')) > 0 or
       exists (select 1 from jsonb_array_elements(coalesce(p_payload->'upserts'->'app_settings', '[]')) e
               where e->>'key' in ('currency', 'revenue_purposes'))) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], p_payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], p_payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.profile_status(), public.profile_login(text, text),
  public.admin_set_profile_password(text, text, text) from public;
grant execute on function public.profile_status(), public.profile_login(text, text),
  public.admin_set_profile_password(text, text, text) to anon, authenticated;
