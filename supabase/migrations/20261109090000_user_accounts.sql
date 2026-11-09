-- ===== User accounts (2026-11-09) =====
-- Everyone signs in with their own username and password instead of the
-- four shared profiles. Passwords are kept here only as bcrypt hashes, in
-- the private schema the API does not expose. Only an admin creates
-- accounts, resets passwords and gives out roles.
--
-- Sign-ins reuse private.admin_tokens: a user's token carries the user's
-- role, so every existing function (sync_read, sync_push, ...) keeps working
-- and treats them exactly as that role.
--
-- The old shared profiles keep working for app builds that don't know about
-- accounts yet; 20261109190000_user_accounts_step2.sql removes them once
-- every device has the new app.

create table if not exists private.app_users (
  id              bigint generated always as identity primary key,
  username        text not null unique
                  check (username ~ '^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$'),
  full_name       text not null check (length(trim(full_name)) > 0),
  role            text not null
                  check (role in ('admin', 'admin_team', 'director', 'team')),
  staff_id        bigint,
  hash            text not null,
  active          boolean not null default true,
  must_change     boolean not null default true,
  failed_attempts integer not null default 0,
  locked_until    timestamptz,
  last_sign_in    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Tokens now say which user they belong to (null: an old shared profile),
-- and whether "Remember me" was ticked (30 days, else a day).
alter table private.admin_tokens
  add column if not exists user_id bigint references private.app_users(id) on delete cascade;
alter table private.admin_tokens
  add column if not exists remember boolean not null default true;
create index if not exists admin_tokens_user_idx on private.admin_tokens(user_id);

-- The existing admin becomes the first account: username "admin", same
-- password as today (both are bcrypt hashes).
insert into private.app_users (username, full_name, role, hash, must_change)
  select 'admin', 'Admin', 'admin', s.hash, false
  from private.admin_secret s
  where s.id = 1
    and not exists (select 1 from private.app_users)
  on conflict (username) do nothing;

-- ---- Helpers ---------------------------------------------------------------

create or replace function private.user_json(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', u.id,
    'username', u.username,
    'full_name', u.full_name,
    'role', u.role,
    'staff_id', u.staff_id,
    'active', u.active,
    'must_change', u.must_change,
    'last_sign_in', u.last_sign_in,
    'locked', coalesce(u.locked_until > now(), false)
  )
  from private.app_users u where u.id = p_id;
$$;

create or replace function private.new_user_token(p_user bigint, p_remember boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare
  t text := encode(extensions.gen_random_bytes(32), 'hex');
  r text;
begin
  select role into r from private.app_users where id = p_user;
  delete from private.admin_tokens where expires_at < now();
  insert into private.admin_tokens (token_hash, role, user_id, remember, expires_at)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), r, p_user,
            coalesce(p_remember, false),
            now() + case when coalesce(p_remember, false)
                         then interval '30 days' else interval '1 day' end);
  return t;
end $$;

-- The signed-in user behind a token; refuses a missing, expired or
-- non-user token, and a deactivated account.
create or replace function private.token_user(p_token text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare uid bigint;
begin
  select t.user_id into uid
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active
    where t.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and t.expires_at > now();
  if uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  return uid;
end $$;

create or replace function private.check_password(p_password text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if length(coalesce(p_password, '')) < 8 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
end $$;

-- Usernames: lower case letters, digits, dots, dashes, underscores; 3 to 32
-- characters, starting and ending with a letter or digit.
create or replace function private.clean_username(p_username text)
returns text language plpgsql immutable set search_path = '' as $$
declare u text := lower(trim(coalesce(p_username, '')));
begin
  if u !~ '^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$' then
    raise exception 'bad_username' using errcode = '22023';
  end if;
  return u;
end $$;

-- ---- Sign in / out -----------------------------------------------------------

-- 'empty' until the first account exists (a brand-new online database),
-- else 'ready'.
create or replace function public.users_status()
returns text language sql security definer set search_path = '' as $$
  select case when exists (select 1 from private.app_users) then 'ready' else 'empty' end;
$$;

-- A brand-new online database: the first account, an admin.
create or replace function public.user_setup(
  p_username text, p_full_name text, p_password text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid bigint;
  v_name text := private.clean_username(p_username);
begin
  perform private.check_password(p_password);
  if length(trim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'bad_name' using errcode = '22023';
  end if;
  lock table private.app_users in exclusive mode;
  if exists (select 1 from private.app_users) then
    raise exception 'already_claimed' using errcode = '42501';
  end if;
  insert into private.app_users (username, full_name, role, hash, must_change, last_sign_in)
    values (v_name, trim(p_full_name), 'admin',
            extensions.crypt(p_password, extensions.gen_salt('bf', 10)), false, now())
    returning id into uid;
  return jsonb_build_object('token', private.new_user_token(uid, false),
                            'user', private.user_json(uid));
end $$;

-- Signs in. Returns {"token": ..., "user": {...}} or {"error": code}:
-- wrong_password (unknown username too, so names can't be guessed),
-- locked (5 wrong passwords in a row: 15 minutes), deactivated.
-- Errors are returned rather than raised so the attempt count is kept.
create or replace function public.user_login(
  p_username text, p_password text, p_remember boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u private.app_users;
  tries integer;
begin
  select * into u from private.app_users
    where username = lower(trim(coalesce(p_username, '')));
  if u.id is null then
    perform pg_sleep(0.5);
    return jsonb_build_object('error', 'wrong_password');
  end if;
  if u.locked_until is not null and u.locked_until > now() then
    return jsonb_build_object('error', 'locked', 'until', u.locked_until);
  end if;
  if extensions.crypt(coalesce(p_password, ''), u.hash) <> u.hash then
    tries := u.failed_attempts + 1;
    update private.app_users
      set failed_attempts = case when tries >= 5 then 0 else tries end,
          locked_until = case when tries >= 5 then now() + interval '15 minutes' end
      where id = u.id;
    perform pg_sleep(0.5);
    return jsonb_build_object('error', case when tries >= 5 then 'locked' else 'wrong_password' end);
  end if;
  if not u.active then
    return jsonb_build_object('error', 'deactivated');
  end if;
  update private.app_users
    set failed_attempts = 0, locked_until = null, last_sign_in = now()
    where id = u.id;
  return jsonb_build_object('token', private.new_user_token(u.id, p_remember),
                            'user', private.user_json(u.id));
end $$;

-- Checks a kept sign-in when the app opens (and now and then while it is
-- open): the user's latest details, and another 30 days (or a day) from now.
create or replace function public.user_session(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.token_user(p_token);
begin
  update private.admin_tokens
    set expires_at = now() + case when remember then interval '30 days' else interval '1 day' end
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  return private.user_json(uid);
end $$;

create or replace function public.user_logout(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from private.admin_tokens
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- The user's own new password (also the first sign-in after the admin set
-- a temporary one). Other devices signed in as them must sign in again.
create or replace function public.user_change_password(
  p_token text, p_current text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user(p_token);
  h text;
begin
  perform private.check_password(p_new);
  select hash into h from private.app_users where id = uid;
  if extensions.crypt(coalesce(p_current, ''), h) <> h then
    perform pg_sleep(0.5);
    raise exception 'wrong_password' using errcode = '28P01';
  end if;
  if p_new = p_current then
    raise exception 'same_password' using errcode = '22023';
  end if;
  update private.app_users
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        must_change = false, updated_at = now()
    where id = uid;
  delete from private.admin_tokens
    where user_id = uid
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- ---- Admin: accounts -------------------------------------------------------

create or replace function public.admin_list_users(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  return coalesce((
    select jsonb_agg(private.user_json(id) order by active desc, lower(full_name))
    from private.app_users), '[]'::jsonb);
end $$;

-- Creates (no "id") or changes an account:
-- {"id", "username", "full_name", "role", "staff_id", "active", "password"}.
-- A new account needs a temporary "password"; its owner chooses their own
-- at first sign-in. A new role, or deactivating, signs the user out.
create or replace function public.admin_save_user(p_token text, p_user jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint;
  uid bigint := nullif(p_user->>'id', '')::bigint;
  v_name text := private.clean_username(p_user->>'username');
  v_full text := trim(coalesce(p_user->>'full_name', ''));
  v_role text := coalesce(p_user->>'role', 'team');
  v_staff bigint := nullif(p_user->>'staff_id', '')::bigint;
  v_active boolean := coalesce((p_user->>'active')::boolean, true);
  before private.app_users;
begin
  perform private.check_token(p_token);
  begin
    me := private.token_user(p_token);
  exception when others then
    me := null; -- the old shared admin profile
  end;
  if length(v_full) = 0 then
    raise exception 'bad_name' using errcode = '22023';
  end if;
  if v_role not in ('admin', 'admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  if exists (select 1 from private.app_users
             where username = v_name and id is distinct from uid) then
    raise exception 'username_taken' using errcode = '23505';
  end if;
  if uid is null then
    perform private.check_password(p_user->>'password');
    insert into private.app_users (username, full_name, role, staff_id, hash, active, must_change)
      values (v_name, v_full, v_role, v_staff,
              extensions.crypt(p_user->>'password', extensions.gen_salt('bf', 10)),
              v_active, true)
      returning id into uid;
    return private.user_json(uid);
  end if;
  select * into before from private.app_users where id = uid for update;
  if before.id is null then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  if uid = me and (not v_active or v_role <> 'admin') then
    raise exception 'own_account' using errcode = '42501';
  end if;
  update private.app_users
    set username = v_name, full_name = v_full, role = v_role,
        staff_id = v_staff, active = v_active, updated_at = now()
    where id = uid;
  if not exists (select 1 from private.app_users where role = 'admin' and active) then
    raise exception 'last_admin' using errcode = '42501';
  end if;
  if before.role <> v_role or (before.active and not v_active) then
    delete from private.admin_tokens where user_id = uid;
  end if;
  return private.user_json(uid);
end $$;

-- A temporary password for a user who forgot theirs: they choose their own
-- at the next sign-in, and are signed out everywhere until then.
create or replace function public.admin_reset_password(
  p_token text, p_user_id bigint, p_password text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  perform private.check_password(p_password);
  update private.app_users
    set hash = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
        must_change = true, failed_attempts = 0, locked_until = null,
        updated_at = now()
    where id = p_user_id;
  if not found then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  delete from private.admin_tokens where user_id = p_user_id;
end $$;

-- ---- Access ------------------------------------------------------------------

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.users_status(), public.user_setup(text, text, text),
  public.user_login(text, text, boolean), public.user_session(text),
  public.user_logout(text), public.user_change_password(text, text, text),
  public.admin_list_users(text), public.admin_save_user(text, jsonb),
  public.admin_reset_password(text, bigint, text) from public;
grant execute on function public.users_status(), public.user_setup(text, text, text),
  public.user_login(text, text, boolean), public.user_session(text),
  public.user_logout(text), public.user_change_password(text, text, text),
  public.admin_list_users(text), public.admin_save_user(text, jsonb),
  public.admin_reset_password(text, bigint, text) to anon, authenticated;
