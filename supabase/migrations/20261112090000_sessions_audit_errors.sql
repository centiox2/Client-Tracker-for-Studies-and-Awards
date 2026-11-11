-- ===== Sessions, audit log, error reports (2026-11-12) =====
--
-- 1. Sessions: each sign-in notes the device it's on and when it was last
--    used, so people can see where they're signed in and sign out of one
--    device or all the others.
-- 2. Audit log: who changed what, across payments, weeks, staff, time off,
--    notes, settings, departments, daily reports and accounts. The person is
--    noted when their sign-in is checked (token_role / token_user); triggers
--    write the changes. Client numbers and applications keep their own
--    change histories (count_changes, application_changes).
-- 3. Error reports: the app sends unexpected errors here (deduplicated, with
--    a daily cap) so they're seen before anyone reports them.

-- ---- 1. Sessions ---------------------------------------------------------

alter table private.admin_tokens add column if not exists device text;
alter table private.admin_tokens add column if not exists last_seen timestamptz;

-- Who is acting, for the audit log: set whenever a sign-in is checked.
create or replace function private.note_actor(p_token_hash text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  who text;
  uid bigint;
begin
  select coalesce(u.full_name, u.username, initcap(replace(t.role, '_', ' '))),
         t.user_id
    into who, uid
    from private.admin_tokens t
    left join private.app_users u on u.id = t.user_id
    where t.token_hash = p_token_hash;
  perform set_config('app.actor', coalesce(who, ''), true);
  perform set_config('app.actor_id', coalesce(uid::text, ''), true);
end $$;

create or replace function private.token_role(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  r text;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  select role into r from private.admin_tokens
    where token_hash = h and expires_at > now();
  if r is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return r;
end $$;

create or replace function private.token_user(p_token text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid bigint;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  select t.user_id into uid
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active
    where t.token_hash = h and t.expires_at > now();
  if uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return uid;
end $$;

-- The app says which device this sign-in is on (on start and when the
-- session is checked); also "last used".
create or replace function public.user_session_touch(p_token text, p_device text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.token_user(p_token);
  update private.admin_tokens
    set device = left(nullif(trim(coalesce(p_device, '')), ''), 80),
        last_seen = now()
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- The signed-in person's sessions, newest use first. "id" is a short,
-- harmless handle (never the token or its full hash).
create or replace function public.user_sessions(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user(p_token);
  mine text := encode(extensions.digest(p_token, 'sha256'), 'hex');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', left(t.token_hash, 16),
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

-- Signs out one session (by its id) or, with p_id null, every other one.
create or replace function public.user_sign_out_sessions(p_token text, p_id text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user(p_token);
  mine text := encode(extensions.digest(p_token, 'sha256'), 'hex');
  n integer;
begin
  delete from private.admin_tokens
    where user_id = uid and token_hash <> mine
      and (p_id is null or left(token_hash, 16) = p_id);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---- 2. Audit log ----------------------------------------------------------

create table if not exists private.audit_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  actor      text not null default '',
  actor_id   bigint,
  action     text not null,          -- added / changed / deleted
  table_name text not null,
  record_id  text,
  changed    text[] not null default '{}',
  old_row    jsonb,
  new_row    jsonb
);
create index if not exists audit_log_at on private.audit_log (at desc);

-- Never keep passwords, hashes, secrets or tokens in the log.
create or replace function private.audit_clean(p jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when p is null then null else (
    select coalesce(jsonb_object_agg(k, v), '{}')
    from jsonb_each(p) as e(k, v)
    where k !~* '(password|hash|secret|token|salt)'
  ) end;
$$;

create or replace function private.audit_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then private.audit_clean(to_jsonb(old)) end;
  n jsonb := case when tg_op <> 'DELETE' then private.audit_clean(to_jsonb(new)) end;
  keys text[];
  pk text;
begin
  if tg_op = 'UPDATE' then
    -- Re-uploads write rows unchanged: nothing to note.
    select array_agg(k order by k) into keys
      from jsonb_object_keys(n) k
      -- Sign-ins and lock-outs aren't edits.
      where k not in ('updated_at', 'last_login', 'last_seen', 'last_sign_in',
                      'failed_logins', 'failed_attempts', 'tries',
                      'locked_until')
        and (o -> k) is distinct from (n -> k);
    if keys is null then return null; end if;
  end if;
  pk := coalesce(n, o) ->> case tg_table_name
    when 'app_settings' then 'key'
    when 'day_notes' then 'day_id'
    else 'id' end;
  insert into private.audit_log (actor, actor_id, action, table_name,
                                 record_id, changed, old_row, new_row)
  values (
    coalesce(nullif(current_setting('app.actor', true), ''), 'System'),
    nullif(current_setting('app.actor_id', true), '')::bigint,
    case tg_op when 'INSERT' then 'added' when 'UPDATE' then 'changed'
               else 'deleted' end,
    tg_table_name, pk, coalesce(keys, '{}'), o, n);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['revenue_entries', 'weeks', 'staff', 'staff_day_off',
    'day_notes', 'app_settings', 'departments', 'activity_reports',
    'report_comments']
  loop
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format(
      'create trigger audit_row after insert or update or delete on public.%I '
      'for each row execute function private.audit_row()', t);
  end loop;
  drop trigger if exists audit_row on private.app_users;
  create trigger audit_row after insert or update or delete on private.app_users
    for each row execute function private.audit_row();
end $$;

-- Admins: the log, newest first, a page at a time (before an id).
create or replace function public.audit_list(
  p_token text, p_before bigint default null, p_limit integer default 100,
  p_table text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if private.token_role(p_token) <> 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(a) order by a.id desc)
    from (
      select * from private.audit_log
      where (p_before is null or id < p_before)
        and (p_table is null or table_name = p_table)
      order by id desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) a), '[]');
end $$;

-- ---- 3. Error reports ------------------------------------------------------

create table if not exists private.error_reports (
  id          bigserial primary key,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  count       integer not null default 1,
  fingerprint text not null unique,
  message     text not null,
  stack       text not null default '',
  app_version text not null default '',
  platform    text not null default '',
  who         text not null default ''
);

-- Anyone running the app may report (even before signing in). The same
-- error is counted, not stored again; at most 300 new kinds a day.
create or replace function public.report_error(p_token text, p_report jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  msg text := left(coalesce(p_report ->> 'message', ''), 2000);
  stk text := left(coalesce(p_report ->> 'stack', ''), 8000);
  ver text := left(coalesce(p_report ->> 'version', ''), 40);
  fp text;
  v_who text := '';
begin
  if msg = '' then return; end if;
  begin
    if p_token is not null then
      perform private.token_role(p_token);
      v_who := current_setting('app.actor', true);
    end if;
  exception when others then v_who := '';
  end;
  fp := encode(extensions.digest(msg || '|' || left(stk, 600) || '|' || ver, 'sha256'), 'hex');
  update private.error_reports
    set count = error_reports.count + 1, last_seen = now(),
        who = coalesce(nullif(v_who, ''), error_reports.who)
    where fingerprint = fp;
  if found then return; end if;
  if (select count(*) from private.error_reports
      where first_seen > now() - interval '1 day') >= 300 then
    return;
  end if;
  insert into private.error_reports (fingerprint, message, stack, app_version,
                                     platform, who)
  values (fp, msg, stk, ver,
          left(coalesce(p_report ->> 'platform', ''), 40), coalesce(v_who, ''));
end $$;

create or replace function public.error_list(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if private.token_role(p_token) <> 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(e) - 'fingerprint' order by e.last_seen desc)
    from (select * from private.error_reports
          order by last_seen desc limit 100) e), '[]');
end $$;

create or replace function public.error_clear(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if private.token_role(p_token) <> 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from private.error_reports;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.user_session_touch(text, text),
  public.user_sessions(text), public.user_sign_out_sessions(text, text),
  public.audit_list(text, bigint, integer, text), public.report_error(text, jsonb),
  public.error_list(text), public.error_clear(text) from public;
grant execute on function public.user_session_touch(text, text),
  public.user_sessions(text), public.user_sign_out_sessions(text, text),
  public.audit_list(text, bigint, integer, text), public.report_error(text, jsonb),
  public.error_list(text), public.error_clear(text) to anon, authenticated;
