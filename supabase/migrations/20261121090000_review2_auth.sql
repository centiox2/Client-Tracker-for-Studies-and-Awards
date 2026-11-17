-- Second review: sign-in hardening.
--
-- 1.3  Admin password, recovery code and profile passwords lock after 5
--      wrong tries for 15 minutes, like account sign-in. A raised error
--      rolls the whole call back (and with it any try counter), so a wrong
--      password now returns NULL instead; the app reads NULL as
--      "wrong password" / "wrong recovery code".
-- 1.4  Admin and profile passwords need 8 characters, like accounts.
-- M12  A kept sign-in still slides forward, but never past 90 days from
--      sign-in (14 days when "keep me signed in" is off).
-- M13  A locked account no longer says until when.
-- M14  Error reports without a sign-in: fewer per day and shorter.
-- M15  An online restore is size-checked and keeps the to-do limit.
-- L1   Session ids are the full token hash.
-- L4   A sign-in row made without an expiry lasts 1 day, not 180.
-- L8   Leftover table rights for anon/authenticated are taken away.

create table if not exists private.login_throttle (
  key text primary key,
  failed integer not null default 0,
  locked_until timestamptz
);
alter table private.login_throttle enable row level security;
revoke all on private.login_throttle from public, anon, authenticated;

create or replace function private.throttle_check(p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from private.login_throttle
             where key = p_key and locked_until > now()) then
    raise exception 'locked' using errcode = '28000';
  end if;
end $$;

-- Counts a wrong try; the 5th locks for 15 minutes.
create or replace function private.throttle_fail(p_key text)
returns void language plpgsql security definer set search_path = '' as $$
declare tries integer;
begin
  insert into private.login_throttle (key, failed) values (p_key, 1)
    on conflict (key) do update
      set failed = case when login_throttle.locked_until <= now()
                        then 1 else login_throttle.failed + 1 end,
          locked_until = case when login_throttle.locked_until <= now()
                              then null else login_throttle.locked_until end
    returning failed into tries;
  if tries >= 5 then
    update private.login_throttle
      set failed = 0, locked_until = now() + interval '15 minutes'
      where key = p_key;
  end if;
end $$;

create or replace function private.throttle_ok(p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from private.login_throttle where key = p_key;
end $$;

revoke all on function private.throttle_check(text) from public, anon, authenticated;
revoke all on function private.throttle_fail(text) from public, anon, authenticated;
revoke all on function private.throttle_ok(text) from public, anon, authenticated;

-- L4: a forgotten expiry gives a short sign-in.
alter table private.admin_tokens
  alter column expires_at set default now() + interval '1 day';

create or replace function private.new_token(p_role text default 'admin')
returns text language plpgsql security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from private.admin_tokens where expires_at < now();
  insert into private.admin_tokens (token_hash, role, expires_at)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), p_role,
            now() + interval '30 days');
  return t;
end $$;

create or replace function public.admin_claim(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  perform private.accounts_only();
  perform private.check_password(p_password);
  insert into private.admin_secret (id, hash)
    values (1, extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
    on conflict (id) do nothing;
  if not found then
    raise exception 'already_claimed' using errcode = '42501';
  end if;
  return private.new_token();
end $$;

create or replace function public.admin_login(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare h text;
begin
  perform private.accounts_only();
  select hash into h from private.admin_secret where id = 1;
  if h is null then
    raise exception 'unclaimed' using errcode = '42501';
  end if;
  perform private.throttle_check('admin');
  if extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform private.throttle_fail('admin');
    perform pg_sleep(0.5);
    return null;
  end if;
  perform private.throttle_ok('admin');
  return private.new_token();
end $$;

create or replace function public.admin_recover(p_code text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  stored text;
  code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  perform private.accounts_only();
  perform private.check_password(p_new);
  perform private.throttle_check('recover');
  if length(code) = 16 then
    code := substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' ||
            substr(code, 9, 4) || '-' || substr(code, 13, 4);
  end if;
  select recovery_hash into stored from private.admin_secret where id = 1;
  if stored is null or extensions.crypt(code, stored) <> stored then
    perform private.throttle_fail('recover');
    perform pg_sleep(1);
    return null;
  end if;
  perform private.throttle_ok('recover');
  perform private.throttle_ok('admin');
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        recovery_hash = null,
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens where user_id is null;
  return private.new_token();
end $$;

create or replace function public.admin_set_password(p_token text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  perform private.check_password(p_new);
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens
    where role = 'admin' and user_id is null
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

create or replace function public.admin_set_profile_password(p_token text, p_role text, p_password text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  if p_role not in ('admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  if coalesce(p_password, '') <> '' then
    perform private.check_password(p_password);
  end if;
  update private.profile_secret
    set hash = case when coalesce(p_password, '') = '' then null
                    else extensions.crypt(p_password, extensions.gen_salt('bf', 10)) end,
        updated_at = now()
    where role = p_role;
  delete from private.admin_tokens where role = p_role and user_id is null;
  perform private.throttle_ok('profile:' || p_role);
end $$;

create or replace function public.profile_login(p_role text, p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare h text;
begin
  perform private.accounts_only();
  if p_role not in ('admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  select hash into h from private.profile_secret where role = p_role;
  if h is not null then
    perform private.throttle_check('profile:' || p_role);
    if extensions.crypt(coalesce(p_password, ''), h) <> h then
      perform private.throttle_fail('profile:' || p_role);
      perform pg_sleep(0.5);
      return null;
    end if;
    perform private.throttle_ok('profile:' || p_role);
  end if;
  return private.new_token(p_role);
end $$;

-- M13: no lock expiry in the reply.
create or replace function public.user_login(p_username text, p_password text, p_remember boolean)
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
    perform pg_sleep(0.5);
    return jsonb_build_object('error', 'locked');
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

-- M12: sliding, with a hard end.
create or replace function public.user_session(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.token_user_any(p_token);
begin
  update private.admin_tokens
    set expires_at = least(
          now() + case when remember then interval '30 days' else interval '1 day' end,
          created_at + case when remember then interval '90 days' else interval '14 days' end)
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  return private.user_json(uid);
end $$;

-- L1: full hash as the session id.
create or replace function public.user_sessions(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user(p_token);
  mine text := encode(extensions.digest(p_token, 'sha256'), 'hex');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.token_hash,
      'device', coalesce(t.device, 'Unknown device'),
      'signed_in', t.created_at,
      'last_seen', coalesce(t.last_seen, t.created_at),
      'expires', t.expires_at,
      'remember', t.remember,
      'current', t.token_hash = mine)
      order by coalesce(t.last_seen, t.created_at) desc)
    from private.admin_tokens t
    where t.user_id = uid and t.expires_at > now()), '[]');
end $$;

create or replace function public.user_sign_out_sessions(p_token text, p_id text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user(p_token);
  mine text := encode(extensions.digest(p_token, 'sha256'), 'hex');
  n integer;
begin
  delete from private.admin_tokens
    where user_id = uid and token_hash <> mine
      and (p_id is null or token_hash = p_id);
  get diagnostics n = row_count;
  return n;
end $$;

-- M14: reports without a sign-in are capped harder and kept short. The
-- per-source cap uses a header a sender can change, so the daily total is
-- what bounds them.
create or replace function public.report_error(p_token text, p_report jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  msg text := left(coalesce(p_report ->> 'message', ''), 2000);
  stk text := left(coalesce(p_report ->> 'stack', ''), 8000);
  ver text := left(coalesce(p_report ->> 'version', ''), 40);
  fp text;
  v_who text := '';
  v_source text := '';
  v_headers jsonb;
begin
  if msg = '' then return; end if;
  begin
    if p_token is not null then
      perform private.token_role(p_token);
      v_who := coalesce(current_setting('app.actor', true), '');
    end if;
  exception when others then v_who := '';
  end;
  if v_who = '' then
    msg := left(msg, 500);
    stk := left(stk, 2000);
  end if;
  fp := encode(extensions.digest(msg || '|' || left(stk, 600) || '|' || ver, 'sha256'), 'hex');
  update private.error_reports
    set count = error_reports.count + 1, last_seen = now(),
        who = coalesce(nullif(v_who, ''), error_reports.who)
    where fingerprint = fp;
  if found then return; end if;
  if v_who <> '' then
    if (select count(*) from private.error_reports
        where who <> '' and first_seen > now() - interval '1 day') >= 300 then
      return;
    end if;
  else
    begin
      v_headers := current_setting('request.headers', true)::jsonb;
    exception when others then v_headers := null;
    end;
    v_source := encode(extensions.digest(coalesce(
      v_headers ->> 'cf-connecting-ip',
      split_part(v_headers ->> 'x-forwarded-for', ',', 1), ''), 'sha256'), 'hex');
    if (select count(*) from private.error_reports
        where who = '' and first_seen > now() - interval '1 day') >= 30
       or (select count(*) from private.error_reports
           where who = '' and source = v_source
             and first_seen > now() - interval '1 day') >= 5 then
      return;
    end if;
  end if;
  insert into private.error_reports (fingerprint, message, stack, app_version,
                                     platform, who, source)
  values (fp, msg, stk, ver,
          left(coalesce(p_report ->> 'platform', ''), 40), v_who, v_source);
end $$;

-- M15: size and to-do limits on an online restore.
create or replace function public.admin_restore_online(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_dept int; n_rep int; n_chg int; n_com int; n_todo int; n_team int;
begin
  perform private.check_token(p_token);
  if p_data is null or jsonb_typeof(p_data) <> 'object'
     or pg_column_size(p_data) > 64 * 1024 * 1024 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_data->'departments', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'activity_reports', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'activity_changes', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'report_comments', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'todo_items', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'todo_team_items', '[]')) <> 'array'
     or jsonb_array_length(coalesce(p_data->'departments', '[]')) > 1000
     or jsonb_array_length(coalesce(p_data->'activity_reports', '[]')) > 500000
     or jsonb_array_length(coalesce(p_data->'activity_changes', '[]')) > 2000000
     or jsonb_array_length(coalesce(p_data->'report_comments', '[]')) > 500000
     or jsonb_array_length(coalesce(p_data->'todo_items', '[]')) > 300000
     or jsonb_array_length(coalesce(p_data->'todo_team_items', '[]')) > 300000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.departments overriding system value
    select * from jsonb_populate_recordset(null::public.departments,
                                           coalesce(p_data->'departments', '[]'))
    on conflict (id) do nothing;
  get diagnostics n_dept = row_count;

  insert into public.activity_reports overriding system value
    select (jsonb_populate_record(null::public.activity_reports,
             x || jsonb_build_object(
               'assigned_by', private.known_user(x->'assigned_by'),
               'reviewed_by', private.known_user(x->'reviewed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_reports', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
      and (x->>'department_id' is null
           or exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint))
    on conflict (id) do nothing;
  get diagnostics n_rep = row_count;

  -- History rows keep their ids so a restore is faithful; only an admin
  -- can restore, and existing rows are never replaced.
  insert into public.activity_changes overriding system value
    select (jsonb_populate_record(null::public.activity_changes,
             x || jsonb_build_object('changed_by', private.known_user(x->'changed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_changes', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_chg = row_count;

  insert into public.report_comments overriding system value
    select (jsonb_populate_record(null::public.report_comments,
             x || jsonb_build_object('user_id', private.known_user(x->'user_id')))).*
    from jsonb_array_elements(coalesce(p_data->'report_comments', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_com = row_count;

  insert into public.todo_items
    select (jsonb_populate_record(null::public.todo_items,
             x || jsonb_build_object('extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_items', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
    on conflict (user_id, id) do nothing;
  get diagnostics n_todo = row_count;

  insert into public.todo_team_items
    select (jsonb_populate_record(null::public.todo_team_items,
             x || jsonb_build_object(
               'changed_by', private.known_user(x->'changed_by'),
               'extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_team_items', '[]')) x
    where exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint)
    on conflict (department_id, id) do nothing;
  get diagnostics n_team = row_count;

  -- The same limit todo_sync keeps.
  if exists (select 1 from public.todo_items group by user_id having count(*) > 3000)
     or exists (select 1 from public.todo_team_items group by department_id
                having count(*) > 3000) then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  perform setval(pg_get_serial_sequence('public.departments', 'id'),
                 greatest(coalesce((select max(id) from public.departments), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_reports', 'id'),
                 greatest(coalesce((select max(id) from public.activity_reports), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_changes', 'id'),
                 greatest(coalesce((select max(id) from public.activity_changes), 0), 1));
  perform setval(pg_get_serial_sequence('public.report_comments', 'id'),
                 greatest(coalesce((select max(id) from public.report_comments), 0), 1));
  return jsonb_build_object('departments', n_dept, 'reports', n_rep,
                            'changes', n_chg, 'comments', n_com,
                            'todos', n_todo, 'team_todos', n_team);
end $$;

-- L8: only the "something changed" ping is readable, and only that.
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables
           where schemaname in ('public', 'private') loop
    execute format('revoke all on %I.%I from anon, authenticated',
                   t.schemaname, t.tablename);
  end loop;
end $$;
grant select on public.sync_ping to anon, authenticated;

-- 1.8: an empty page list means no pages; only null means every page.
create or replace function public.admin_set_user_pages(
  p_token text, p_user_id bigint, p_pages text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v text[];
begin
  perform private.check_token(p_token);
  if not exists (select 1 from private.app_users where id = p_user_id) then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  if p_pages is not null then
    select coalesce(array_agg(distinct p order by p), '{}') into v
      from unnest(p_pages) p
      where p in ('home', 'dailyReports', 'week', 'revenue', 'applications',
                  'history', 'staff', 'reports', 'settings');
  end if;
  update private.app_users
    set pages = v, updated_at = now()
    where id = p_user_id;
  return private.user_json(p_user_id);
end $$;
