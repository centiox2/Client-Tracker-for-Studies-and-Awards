-- ===== Security tightening, page access, full backup (2026-11-12) =====
--
-- 1. No data without an account. The publishable key (inside every copy of
--    the app) could still read the synced tables directly, and the old
--    sync_snapshot() returned everything, revenue included, to anyone. Both
--    are closed: data is read only with a sign-in (sync_read). Live updates
--    keep coming through sync_ping, which holds no data.
-- 2. The shared profiles and the old shared admin password were replaced by
--    personal accounts. Once any account exists, their sign-ins refuse, so
--    nobody can get in without an account of their own.
-- 3. Page access: an admin can limit which pages each account opens
--    (null = everything the role allows).
-- 4. Full backup: an admin can download everything that lives only online
--    (daily reports, their history and comments, departments, accounts
--    without passwords, the audit log) and put back reports that are gone.

-- ---- 1. No open reads -----------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes','applications','application_imports',
    'application_changes','departments','activity_reports','activity_changes',
    'report_comments']
  loop
    execute format('drop policy if exists "Anyone can read" on public.%I', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    begin
      execute format('alter publication supabase_realtime drop table public.%I', t);
    exception when undefined_object or undefined_table then null; end;
  end loop;
end $$;

-- sync_ping only says "something changed" (a time, no data).
revoke insert, update, delete on public.sync_ping from anon, authenticated;

create or replace function public.sync_snapshot()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'update_required' using errcode = '42501';
end $$;

-- ---- 2. Personal accounts only ---------------------------------------------

create or replace function private.accounts_only()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from private.app_users) then
    raise exception 'accounts_only' using errcode = '42501';
  end if;
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
  if h is not null and extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform pg_sleep(0.5);
    raise exception 'wrong_password' using errcode = '28P01';
  end if;
  return private.new_token(p_role);
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
  if extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform pg_sleep(0.5);
    raise exception 'wrong_password' using errcode = '28P01';
  end if;
  return private.new_token();
end $$;

create or replace function public.admin_claim(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  perform private.accounts_only();
  if length(coalesce(p_password, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  insert into private.admin_secret (id, hash)
    values (1, extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
    on conflict (id) do nothing;
  if not found then
    raise exception 'already_claimed' using errcode = '42501';
  end if;
  return private.new_token();
end $$;

do $$
declare src text;
begin
  -- admin_recover: same guard, keeping its body.
  select pg_get_functiondef('public.admin_recover(text, text)'::regprocedure)
    into src;
  if src is not null and position('accounts_only' in src) = 0 then
    src := regexp_replace(src, '(\mbegin\M)', E'\\1\n  perform private.accounts_only();', '');
    execute src;
  end if;
end $$;

-- Sign-ins from the shared profiles (no account) end now.
delete from private.admin_tokens
  where user_id is null and exists (select 1 from private.app_users);

-- ---- 3. Page access ---------------------------------------------------------

alter table private.app_users add column if not exists pages text[];

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
    'locked', coalesce(u.locked_until > now(), false),
    'department_id', u.department_id,
    'report_access', u.report_access,
    'pages', to_jsonb(u.pages)
  )
  from private.app_users u where u.id = p_id;
$$;

-- p_pages: the page names this account opens (null or empty: all its role
-- allows). Unknown names are dropped.
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
  select array_agg(distinct p order by p) into v
    from unnest(coalesce(p_pages, '{}')) p
    where p in ('home', 'dailyReports', 'week', 'revenue', 'applications',
                'history', 'staff', 'reports', 'settings');
  update private.app_users
    set pages = case when coalesce(cardinality(v), 0) = 0 then null else v end,
        updated_at = now()
    where id = p_user_id;
  return private.user_json(p_user_id);
end $$;

-- ---- 4. Full backup -----------------------------------------------------------

create or replace function public.admin_backup(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  return jsonb_build_object(
    'departments', coalesce((select jsonb_agg(t order by t.id) from public.departments t), '[]'),
    'activity_reports', coalesce((select jsonb_agg(t order by t.id) from public.activity_reports t), '[]'),
    'activity_changes', coalesce((select jsonb_agg(t order by t.id) from public.activity_changes t), '[]'),
    'report_comments', coalesce((select jsonb_agg(t order by t.id) from public.report_comments t), '[]'),
    'accounts', coalesce((select jsonb_agg(private.user_json(u.id) order by u.id) from private.app_users u), '[]'),
    'audit_log', coalesce((select jsonb_agg(t order by t.id) from private.audit_log t), '[]')
  );
end $$;

-- Puts back departments, daily reports, their history and comments from a
-- backup. Only rows that are missing are added (nothing is overwritten), and
-- only for accounts that still exist. Returns how many of each came back.
create or replace function public.admin_restore_online(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_dept int; n_rep int; n_chg int; n_com int;
begin
  perform private.check_token(p_token);
  insert into public.departments overriding system value
    select * from jsonb_populate_recordset(null::public.departments,
                                           coalesce(p_data->'departments', '[]'))
    on conflict (id) do nothing;
  get diagnostics n_dept = row_count;
  insert into public.activity_reports overriding system value
    select r.* from jsonb_populate_recordset(null::public.activity_reports,
                                             coalesce(p_data->'activity_reports', '[]')) r
    where exists (select 1 from private.app_users u where u.id = r.user_id)
      and (r.department_id is null
           or exists (select 1 from public.departments d where d.id = r.department_id))
    on conflict (id) do nothing;
  get diagnostics n_rep = row_count;
  insert into public.activity_changes overriding system value
    select c.* from jsonb_populate_recordset(null::public.activity_changes,
                                             coalesce(p_data->'activity_changes', '[]')) c
    where exists (select 1 from public.activity_reports r where r.id = c.report_id)
    on conflict (id) do nothing;
  get diagnostics n_chg = row_count;
  insert into public.report_comments overriding system value
    select c.* from jsonb_populate_recordset(null::public.report_comments,
                                             coalesce(p_data->'report_comments', '[]')) c
    where exists (select 1 from public.activity_reports r where r.id = c.report_id)
      and exists (select 1 from private.app_users u where u.id = c.user_id)
    on conflict (id) do nothing;
  get diagnostics n_com = row_count;
  -- Keep the id sequences ahead of the restored rows.
  perform setval(pg_get_serial_sequence('public.departments', 'id'),
                 greatest(coalesce((select max(id) from public.departments), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_reports', 'id'),
                 greatest(coalesce((select max(id) from public.activity_reports), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_changes', 'id'),
                 greatest(coalesce((select max(id) from public.activity_changes), 0), 1));
  perform setval(pg_get_serial_sequence('public.report_comments', 'id'),
                 greatest(coalesce((select max(id) from public.report_comments), 0), 1));
  return jsonb_build_object('departments', n_dept, 'reports', n_rep,
                            'changes', n_chg, 'comments', n_com);
end $$;

revoke all on function private.accounts_only() from public, anon, authenticated;
revoke all on function public.admin_set_user_pages(text, bigint, text[]),
  public.admin_backup(text), public.admin_restore_online(text, jsonb) from public;
grant execute on function public.admin_set_user_pages(text, bigint, text[]),
  public.admin_backup(text), public.admin_restore_online(text, jsonb)
  to anon, authenticated;
