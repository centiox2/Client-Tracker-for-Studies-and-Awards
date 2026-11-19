-- Client Tracker: online database setup for Supabase.
-- Run this once in a new Supabase project (SQL Editor → New query → paste → Run).
-- It is the same setup as the original project, in the order it was applied,
-- including every security change: when it has run, the publishable key
-- alone reads nothing (no open table reads, and the old open snapshot
-- refuses). Every file in supabase/migrations is already in here; an
-- existing project applies only the migration files it hasn't had yet.

-- ===== client_tracker_schema =====
-- Mirrors the app's local SQLite tables exactly (same ids, dates as ISO text)
-- so rows round-trip unchanged between devices.

create table public.staff (
  id            bigint primary key,
  name          text not null,
  active        integer not null default 1,
  display_order integer not null default 0,
  created_at    text not null
);

create table public.weeks (
  id          bigint primary key,
  start_date  text not null unique,
  end_date    text not null,
  created_at  text not null,
  updated_at  text not null,
  show_zeros  integer not null default 1
);

create table public.work_days (
  id      bigint primary key,
  week_id bigint not null references public.weeks(id) on delete cascade,
  date    text not null unique,
  weekday integer not null
);
create index work_days_week_idx on public.work_days(week_id);

create table public.client_counts (
  id               bigint primary key,
  day_id           bigint not null references public.work_days(id) on delete cascade,
  staff_id         bigint not null references public.staff(id) on delete cascade,
  new_clients      integer not null default 0,
  existing_clients integer not null default 0,
  updated_at       text not null,
  unique (day_id, staff_id)
);
create index client_counts_staff_idx on public.client_counts(staff_id);

create table public.staff_day_off (
  id       bigint primary key,
  day_id   bigint not null references public.work_days(id) on delete cascade,
  staff_id bigint not null references public.staff(id) on delete cascade,
  unique (day_id, staff_id)
);
create index staff_day_off_staff_idx on public.staff_day_off(staff_id);

create table public.day_notes (
  day_id     bigint primary key references public.work_days(id) on delete cascade,
  note       text not null,
  updated_at text not null
);

create table public.app_settings (
  key   text primary key,
  value text not null
);

create table public.count_changes (
  id           bigint primary key,
  day_id       bigint not null references public.work_days(id) on delete cascade,
  staff_id     bigint not null,
  old_new      integer not null,
  old_existing integer not null,
  new_new      integer not null,
  new_existing integer not null,
  changed_at   text not null
);
create index count_changes_day_idx on public.count_changes(day_id);

-- Anyone may read (the boss's view is open); nobody writes directly.
-- All writes go through sync_push(), which checks the admin token.
do $$
declare t text;
begin
  foreach t in array array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "Anyone can read" on public.%I for select to anon, authenticated using (true)', t);
    -- Deletes in live updates must carry the row id.
    execute format('alter table public.%I replica identity full', t);
    execute format('alter publication supabase_realtime add table public.%I', t);
  end loop;
end $$;

-- ===== admin_auth_and_sync =====
-- The admin password (bcrypt hash) and the sign-in tokens devices use to
-- push changes. Kept in a schema the API does not expose.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.admin_secret (
  id   integer primary key default 1 check (id = 1),
  hash text not null,
  updated_at timestamptz not null default now()
);

create table private.admin_tokens (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '180 days'
);

create or replace function private.new_token()
returns text language plpgsql security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from private.admin_tokens where expires_at < now();
  insert into private.admin_tokens (token_hash)
    values (encode(extensions.digest(t, 'sha256'), 'hex'));
  return t;
end $$;

create or replace function private.check_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or not exists (
    select 1 from private.admin_tokens
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and expires_at > now()
  ) then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
end $$;

-- 'unclaimed' until the first admin sign-in sets the password.
create or replace function public.admin_status()
returns text language sql security definer set search_path = '' as $$
  select case when exists (select 1 from private.admin_secret)
              then 'claimed' else 'unclaimed' end;
$$;

-- First sign-in: the admin's password becomes the online password.
create or replace function public.admin_claim(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
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

create or replace function public.admin_login(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare h text;
begin
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
  -- Other devices must sign in again with the new password.
  delete from private.admin_tokens
    where token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

create or replace function public.admin_logout(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from private.admin_tokens
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

-- Upserts JSON rows into one table, matched on its primary key.
create or replace function private.upsert_rows(p_table text, p_pk text, p_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare sets text;
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then return; end if;
  select string_agg(format('%I = excluded.%I', column_name, column_name), ', ')
    into sets
    from information_schema.columns
    where table_schema = 'public' and table_name = p_table
      and column_name <> p_pk;
  execute format(
    'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1) '
    'on conflict (%I) do update set %s',
    p_table, p_table, p_pk, sets) using p_rows;
end $$;

create or replace function private.delete_rows(p_table text, p_pk text, p_keys jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_keys is null or jsonb_array_length(p_keys) = 0 then return; end if;
  execute format(
    'delete from public.%I where %I::text in (select jsonb_array_elements_text($1))',
    p_table, p_pk) using p_keys;
end $$;

-- Applies one batch of changes from the admin's device, all or nothing:
-- {"deletes": {"weeks": [3]}, "upserts": {"staff": [{...}], ...}}
create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id'];
  i int;
begin
  perform private.check_token(p_token);
  -- Deletes first, children before parents (a week deleted and created
  -- again must not collide with itself).
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], p_payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], p_payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

-- Everything, in one call (no row limits), for a device starting up.
create or replace function public.sync_snapshot()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'staff',         coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]'),
    'weeks',         coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]'),
    'work_days',     coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]'),
    'client_counts', coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]'),
    'staff_day_off', coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]'),
    'day_notes',     coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]'),
    'app_settings',  coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes', coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]')
  );
$$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.admin_status(), public.admin_claim(text),
  public.admin_login(text), public.admin_set_password(text, text),
  public.admin_logout(text), public.sync_push(text, jsonb),
  public.sync_snapshot() from public;
grant execute on function public.admin_status(), public.admin_claim(text),
  public.admin_login(text), public.admin_set_password(text, text),
  public.admin_logout(text), public.sync_push(text, jsonb),
  public.sync_snapshot() to anon, authenticated;

-- ===== snapshot_as_invoker =====
-- Reading is already allowed by the tables' policies; no elevated rights needed.
alter function public.sync_snapshot() security invoker;
grant select on public.staff, public.weeks, public.work_days, public.client_counts,
  public.staff_day_off, public.day_notes, public.app_settings, public.count_changes
  to anon, authenticated;

-- ===== revenue_entries (2026-11-03) =====
-- Also in supabase/migrations/20261103120000_revenue_entries.sql.

create table public.revenue_entries (
  id           bigint primary key,
  date         text not null,
  amount_cents bigint not null check (amount_cents > 0),
  note         text not null default '',
  created_at   text not null,
  updated_at   text not null
);
create index revenue_entries_date_idx on public.revenue_entries(date);

-- Same access as every other table: anyone may read, writes only via
-- sync_push() with the admin token.
alter table public.revenue_entries enable row level security;
create policy "Anyone can read" on public.revenue_entries
  for select to anon, authenticated using (true);
alter table public.revenue_entries replica identity full;
alter publication supabase_realtime add table public.revenue_entries;
grant select on public.revenue_entries to anon, authenticated;

create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id'];
  i int;
begin
  perform private.check_token(p_token);
  -- Deletes first, children before parents (a week deleted and created
  -- again must not collide with itself).
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], p_payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], p_payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

create or replace function public.sync_snapshot()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'staff',           coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]'),
    'weeks',           coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]'),
    'work_days',       coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]'),
    'client_counts',   coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]'),
    'staff_day_off',   coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]'),
    'day_notes',       coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]'),
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]'),
    'revenue_entries', coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]')
  );
$$;

-- ===== v9: purpose, refunds, revenue_changes, recovery (2026-11-03) =====
-- Also in supabase/migrations/20261103170000_revenue_v9_and_recovery.sql.

-- What a payment was for. Nullable: older app builds send rows without it.
alter table public.revenue_entries add column if not exists purpose text;

-- Refunds are negative amounts; only zero is meaningless.
alter table public.revenue_entries drop constraint if exists revenue_entries_amount_cents_check;
alter table public.revenue_entries add constraint revenue_entries_amount_cents_check
  check (amount_cents <> 0);

-- Every change to revenue: added / edited / deleted / restored, by device.
create table if not exists public.revenue_changes (
  id               bigint primary key,
  entry_id         bigint not null,
  action           text not null,
  amount_cents     bigint not null,
  date             text not null,
  note             text not null default '',
  old_amount_cents bigint,
  old_date         text,
  old_note         text,
  device           text not null default '',
  changed_at       text not null
);
create index if not exists revenue_changes_at_idx on public.revenue_changes(changed_at);
alter table public.revenue_changes enable row level security;
drop policy if exists "Anyone can read" on public.revenue_changes;
create policy "Anyone can read" on public.revenue_changes
  for select to anon, authenticated using (true);
alter table public.revenue_changes replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.revenue_changes;
exception when duplicate_object then null; end $$;
grant select on public.revenue_changes to anon, authenticated;

create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id','id'];
  i int;
begin
  perform private.check_token(p_token);
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], p_payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], p_payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

create or replace function public.sync_snapshot()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'staff',           coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]'),
    'weeks',           coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]'),
    'work_days',       coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]'),
    'client_counts',   coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]'),
    'staff_day_off',   coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]'),
    'day_notes',       coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]'),
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]'),
    'revenue_entries', coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]'),
    'revenue_changes', coalesce((select jsonb_agg(t order by t.id) from public.revenue_changes t), '[]')
  );
$$;

-- ===== Recovery code for a forgotten online admin password =====
-- A signed-in admin creates a code (shown once; only its bcrypt hash is
-- stored). With it, a new password can be set from any device; the code
-- then stops working and every device must sign in again.
alter table private.admin_secret add column if not exists recovery_hash text;

create or replace function public.admin_create_recovery_code(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea := extensions.gen_random_bytes(16);
  code text := '';
  i int;
begin
  perform private.check_token(p_token);
  for i in 0..15 loop
    code := code || substr(alphabet, (get_byte(bytes, i) % length(alphabet)) + 1, 1);
    if i in (3, 7, 11) then code := code || '-'; end if;
  end loop;
  update private.admin_secret
    set recovery_hash = extensions.crypt(code, extensions.gen_salt('bf', 10))
    where id = 1;
  return code;
end $$;

create or replace function public.admin_recover(p_code text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  stored text;
  code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(coalesce(p_new, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  -- Accept the code with or without its dashes.
  if length(code) = 16 then
    code := substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' ||
            substr(code, 9, 4) || '-' || substr(code, 13, 4);
  end if;
  select recovery_hash into stored from private.admin_secret where id = 1;
  if stored is null or extensions.crypt(code, stored) <> stored then
    perform pg_sleep(1);  -- slow down guessing
    raise exception 'wrong_recovery_code' using errcode = '28000';
  end if;
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        recovery_hash = null,
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens;
  return private.new_token();
end $$;

-- Whether a recovery code exists (so Settings can say so).
create or replace function public.admin_has_recovery(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  return exists (select 1 from private.admin_secret where id = 1 and recovery_hash is not null);
end $$;

revoke all on function public.admin_create_recovery_code(text),
  public.admin_recover(text, text), public.admin_has_recovery(text) from public;
grant execute on function public.admin_create_recovery_code(text),
  public.admin_recover(text, text), public.admin_has_recovery(text) to anon, authenticated;

-- ===== Profiles (2026-11-04) =====
-- Also in supabase/migrations/20261104090000_profiles.sql.

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

-- ===== Profile password versions (2026-11-04) =====
-- When each profile's password last changed, so a device where someone
-- chose "Keep me signed in" asks again after the admin changes it.
create or replace function public.profile_versions()
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(role, updated_at::text), '{}'::jsonb)
  from private.profile_secret;
$$;
revoke all on function public.profile_versions() from public;
grant execute on function public.profile_versions() to anon, authenticated;

-- ===== Secure reads, step 1 (2026-11-04) =====
-- Every profile gets a token when it opens, and the data is read with it:
-- revenue only for the admin and the director. Live updates come through
-- sync_ping, which says only that something changed (no data); devices then
-- read the latest with their token. Step 2 (after every device has the new
-- app) removes the open reads.

-- Every profile now gets a token (the view-only ones too).
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
  return private.new_token(p_role);
end $$;

-- The data, for a signed-in profile. Revenue is empty for profiles that
-- may not see it (so their devices don't keep any).
create or replace function public.sync_read(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  money boolean := r in ('admin', 'director');
begin
  return jsonb_build_object(
    'staff',           coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]'),
    'weeks',           coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]'),
    'work_days',       coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]'),
    'client_counts',   coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]'),
    'staff_day_off',   coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]'),
    'day_notes',       coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]'),
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]'),
    'revenue_entries', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]') else '[]' end,
    'revenue_changes', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_changes t), '[]') else '[]' end
  );
end $$;

-- "Something changed": one row, bumped by every change to the data.
create table if not exists public.sync_ping (
  id integer primary key default 1 check (id = 1),
  at timestamptz not null default now()
);
insert into public.sync_ping (id) values (1) on conflict (id) do nothing;
alter table public.sync_ping enable row level security;
drop policy if exists "Anyone can read" on public.sync_ping;
create policy "Anyone can read" on public.sync_ping
  for select to anon, authenticated using (true);
grant select on public.sync_ping to anon, authenticated;
do $$ begin
  alter publication supabase_realtime add table public.sync_ping;
exception when duplicate_object then null; end $$;

create or replace function private.bump_ping()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.sync_ping set at = now() where id = 1;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes']
  loop
    execute format('drop trigger if exists sync_ping on public.%I', t);
    execute format(
      'create trigger sync_ping after insert or update or delete on public.%I '
      'for each statement execute function private.bump_ping()', t);
  end loop;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.sync_read(text) from public;
grant execute on function public.sync_read(text) to anon, authenticated;

-- ===== Security check (2026-11-04) =====
-- Supabase helper (event trigger function) needs no public execute.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- ===== Applications (2026-11-05) =====
-- The Airtable "Applications Tracker", uploaded as CSV in the app. Student
-- names: never readable with the publishable key alone (no policies, no
-- grants); read only through sync_read with a profile's token, written only
-- through sync_push (admin or admin team). Live updates via sync_ping.

create table if not exists public.applications (
  id          bigint primary key,
  app_key     text not null,
  student     text not null,
  rto         text not null default '',
  country     text not null default '',
  doc_date    text,
  app_date    text,
  offer_date  text,
  coe_date    text,
  status      text not null default '',
  assignee    text not null default '',
  todo        text not null default '',
  follow_up   text not null default '',
  position    integer not null default 0,
  updated_at  text not null
);
create table if not exists public.application_imports (
  id          bigint primary key,
  imported_at text not null,
  file_name   text not null default '',
  total       integer not null default 0,
  added       integer not null default 0,
  changed     integer not null default 0,
  removed     integer not null default 0,
  device      text not null default ''
);
create table if not exists public.application_changes (
  id          bigint primary key,
  import_id   bigint not null,
  app_key     text not null,
  student     text not null,
  field       text not null,
  old_value   text not null default '',
  new_value   text not null default '',
  changed_at  text not null
);

do $$
declare t text;
begin
  foreach t in array array['applications','application_imports','application_changes']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('drop trigger if exists sync_ping on public.%I', t);
    execute format(
      'create trigger sync_ping after insert or update or delete on public.%I '
      'for each statement execute function private.bump_ping()', t);
  end loop;
end $$;

-- Read: every signed-in profile sees applications (no revenue in them).
create or replace function public.sync_read(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  money boolean := r in ('admin', 'director');
begin
  return jsonb_build_object(
    'staff',           coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]'),
    'weeks',           coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]'),
    'work_days',       coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]'),
    'client_counts',   coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]'),
    'staff_day_off',   coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]'),
    'day_notes',       coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]'),
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]'),
    'revenue_entries', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]') else '[]' end,
    'revenue_changes', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_changes t), '[]') else '[]' end,
    'applications',        coalesce((select jsonb_agg(t order by t.id) from public.applications t), '[]'),
    'application_imports', coalesce((select jsonb_agg(t order by t.id) from public.application_imports t), '[]'),
    'application_changes', coalesce((select jsonb_agg(t order by t.id) from public.application_changes t), '[]')
  );
end $$;

-- Write: the admin and the admin team may upload applications.
create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes',
    'applications','application_imports','application_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id','id',
    'id','id','id'];
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

-- ===== User accounts (2026-11-09) =====
-- Also in supabase/migrations/20261109090000_user_accounts.sql.
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

-- ===== Daily activity reports (2026-11-09) =====
-- Also in supabase/migrations/20261109120000_daily_reports.sql.
-- Phase 1 of the Operations Management brief: every person records the
-- work they did each day (with measurable outputs, status, next action,
-- blockers, priority and due date); department heads see their department;
-- the Operations Manager, admins and the director see everything, on a
-- dashboard and in exported reports.
--
-- Unlike client numbers, reports are NOT copied to every device: they are
-- read and written only through the functions below, which check who is
-- asking (their sign-in token) on every call. The tables have row level
-- security on and no grants, so the publishable key alone can't touch them.
--
-- "Today" is Kenya time (Africa/Nairobi).

-- ---- Departments -------------------------------------------------------------

create table if not exists public.departments (
  id         bigint generated always as identity primary key,
  name       text not null unique check (length(trim(name)) > 0),
  -- The measurable outputs this department records, in order:
  -- [{"key": "applications_submitted", "label": "Applications submitted"}]
  outputs    jsonb not null default '[]'::jsonb,
  active     boolean not null default true,
  position   integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.departments enable row level security;
revoke all on public.departments from anon, authenticated;

-- The starting departments from the brief (section 3); the admin can
-- rename, add, or switch any of them off in Settings › Departments.
insert into public.departments (name, outputs, position)
select d.name, d.outputs::jsonb, d.position
from (values
  ('Admissions & Applications', '[
     {"key":"new_inquiries","label":"New inquiries"},
     {"key":"applications_submitted","label":"Applications submitted"},
     {"key":"offers_received","label":"Offers received"},
     {"key":"coes_issued","label":"COEs issued"},
     {"key":"institution_follow_ups","label":"Institution follow-ups"},
     {"key":"missing_documents","label":"Cases missing documents"}]', 1),
  ('Visa Processing & Documentation', '[
     {"key":"documents_checked","label":"Documents checked"},
     {"key":"visa_lodgements","label":"Visa lodgements"},
     {"key":"visa_grants","label":"Visa grants"},
     {"key":"visa_refusals","label":"Visa refusals"},
     {"key":"biometrics_medicals","label":"Biometrics / medical follow-ups"}]', 2),
  ('Finance & Accounts', '[
     {"key":"transactions_processed","label":"Transactions processed"},
     {"key":"school_fee_payments","label":"School fee payments"},
     {"key":"refunds_processed","label":"Refunds processed"},
     {"key":"payment_confirmations","label":"Payment confirmations"}]', 3),
  ('Marketing & Business Development', '[
     {"key":"leads_generated","label":"Leads generated"},
     {"key":"leads_contacted","label":"Leads contacted"},
     {"key":"consultations","label":"Consultations"},
     {"key":"conversions","label":"Students converted"},
     {"key":"partnership_meetings","label":"Partnership meetings"}]', 4),
  ('Administration & Operations', '[
     {"key":"requests_handled","label":"Admin requests handled"},
     {"key":"tasks_completed","label":"Internal tasks completed"},
     {"key":"issues_resolved","label":"Issues resolved"}]', 5),
  ('IELTS & Training', '[
     {"key":"enrolments","label":"Enrolments"},
     {"key":"classes_delivered","label":"Classes delivered"},
     {"key":"learners_attending","label":"Learners attending"},
     {"key":"assessments","label":"Assessments"}]', 6),
  ('Partnerships & Institutional Relations', '[
     {"key":"institutions_contacted","label":"Institutions contacted"},
     {"key":"meetings_held","label":"Meetings held"},
     {"key":"agreements_signed","label":"Agreements signed"},
     {"key":"partner_responses","label":"Partner responses"}]', 7)
) as d(name, outputs, position)
where not exists (select 1 from public.departments);

-- ---- Who belongs where, and what they may see --------------------------------

-- report_access: 'employee' (own reports), 'head' (their department's),
-- 'manager' (every department — the Operations Manager). Admins and the
-- director always see every department.
alter table private.app_users
  add column if not exists department_id bigint references public.departments(id) on delete set null;
alter table private.app_users
  add column if not exists report_access text not null default 'employee';
do $$ begin
  alter table private.app_users add constraint app_users_report_access_check
    check (report_access in ('employee', 'head', 'manager'));
exception when duplicate_object then null; end $$;

-- ---- Reports -----------------------------------------------------------------

create table if not exists public.activity_reports (
  id            bigint generated always as identity primary key,
  user_id       bigint not null references private.app_users(id),
  department_id bigint references public.departments(id) on delete set null,
  report_date   date not null,
  description   text not null check (length(trim(description)) > 0 and length(description) <= 2000),
  reference     text not null default '' check (length(reference) <= 200),
  -- Measurable outputs: {"applications_submitted": 4, ...}
  outputs       jsonb not null default '{}'::jsonb,
  status        text not null check (status in ('completed', 'in_progress', 'pending', 'blocked', 'escalated')),
  next_action   text not null default '' check (length(next_action) <= 1000),
  blocker       text not null default '' check (length(blocker) <= 1000),
  priority      text not null default 'medium' check (priority in ('high', 'medium', 'low')),
  due_date      date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists activity_reports_date_idx on public.activity_reports(report_date);
create index if not exists activity_reports_user_idx on public.activity_reports(user_id, report_date);
create index if not exists activity_reports_dept_idx on public.activity_reports(department_id, report_date);
create index if not exists activity_reports_open_idx on public.activity_reports(due_date)
  where status <> 'completed';
alter table public.activity_reports enable row level security;
revoke all on public.activity_reports from anon, authenticated;

-- Every change, for the audit trail: who, when, what it was before/after.
create table if not exists public.activity_changes (
  id          bigint generated always as identity primary key,
  report_id   bigint not null,
  changed_by  bigint references private.app_users(id),
  action      text not null check (action in ('created', 'edited', 'deleted')),
  before      jsonb,
  after       jsonb,
  changed_at  timestamptz not null default now()
);
create index if not exists activity_changes_report_idx on public.activity_changes(report_id);
alter table public.activity_changes enable row level security;
revoke all on public.activity_changes from anon, authenticated;

-- ---- Helpers -----------------------------------------------------------------

create or replace function private.today()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Africa/Nairobi')::date;
$$;

-- What a user may see: 'all', 'department' or 'own'.
create or replace function private.report_scope(p_user bigint)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when u.role in ('admin', 'director') or u.report_access = 'manager' then 'all'
    when u.report_access = 'head' and u.department_id is not null then 'department'
    else 'own' end
  from private.app_users u where u.id = p_user;
$$;

create or replace function private.can_see_report(p_user bigint, p_owner bigint, p_department bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select case private.report_scope(p_user)
    when 'all' then true
    when 'department' then p_owner = p_user
      or p_department = (select department_id from private.app_users where id = p_user)
    else p_owner = p_user end;
$$;

create or replace function private.report_json(r public.activity_reports)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(r) || jsonb_build_object(
    'user_name', (select full_name from private.app_users where id = r.user_id),
    'department_name', (select name from public.departments where id = r.department_id));
$$;

-- Account details now include the department and report access.
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
    'report_access', u.report_access
  )
  from private.app_users u where u.id = p_id;
$$;

-- Outputs kept as whole numbers from 0 to 100000, for the department's own
-- output keys only; blanks and zeros are left out.
create or replace function private.clean_outputs(p_outputs jsonb, p_department bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(e.key, least(greatest((e.value #>> '{}')::numeric, 0), 100000)::int), '{}'::jsonb)
  from jsonb_each(case when jsonb_typeof(p_outputs) = 'object' then p_outputs else '{}'::jsonb end) e
  where (e.value #>> '{}') ~ '^\s*[0-9]+(\.[0-9]+)?\s*$'
    and (e.value #>> '{}')::numeric > 0
    and e.key in (select o->>'key' from public.departments d,
                  jsonb_array_elements(d.outputs) o where d.id = p_department);
$$;

-- ---- Reading -----------------------------------------------------------------

-- Everything the Daily reports page needs to start: who I am and what I
-- may see, the departments, and the people I may see.
create or replace function public.reports_meta(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
begin
  return jsonb_build_object(
    'today', private.today(),
    'me', private.user_json(me) || jsonb_build_object('scope', scope),
    'departments', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.position, d.name)
      from public.departments d), '[]'::jsonb),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'full_name', u.full_name,
               'department_id', u.department_id, 'active', u.active)
             order by lower(u.full_name))
      from private.app_users u
      where scope = 'all'
         or (scope = 'department' and (u.department_id = my_dept or u.id = me))
         or u.id = me), '[]'::jsonb)
  );
end $$;

-- Reports I may see, newest first. Filter (all optional):
-- {"from": "2026-11-01", "to": "2026-11-09", "department_id": 2,
--  "user_id": 5, "statuses": ["blocked"], "priority": "high",
--  "open_only": true, "overdue_only": true, "search": "visa"}
create or replace function public.report_list(p_token text, p_filter jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_from date := nullif(f->>'from', '')::date;
  v_to date := nullif(f->>'to', '')::date;
  v_dept bigint := nullif(f->>'department_id', '')::bigint;
  v_user bigint := nullif(f->>'user_id', '')::bigint;
  v_statuses text[] := case when jsonb_typeof(f->'statuses') = 'array'
    then array(select jsonb_array_elements_text(f->'statuses')) end;
  v_priority text := nullif(f->>'priority', '');
  v_open boolean := coalesce((f->>'open_only')::boolean, false);
  v_overdue boolean := coalesce((f->>'overdue_only')::boolean, false);
  v_search text := nullif(trim(coalesce(f->>'search', '')), '');
begin
  return coalesce((
    select jsonb_agg(private.report_json(r) order by r.report_date desc, r.created_at desc)
    from (
      select * from public.activity_reports r
      where private.can_see_report(me, r.user_id, r.department_id)
        and (v_from is null or r.report_date >= v_from)
        and (v_to is null or r.report_date <= v_to)
        and (v_dept is null or r.department_id = v_dept)
        and (v_user is null or r.user_id = v_user)
        and (v_statuses is null or r.status = any(v_statuses))
        and (v_priority is null or r.priority = v_priority)
        and (not v_open or r.status <> 'completed')
        and (not v_overdue or (r.status <> 'completed' and r.due_date < private.today()))
        and (v_search is null
             or r.description ilike '%' || v_search || '%'
             or r.reference ilike '%' || v_search || '%'
             or r.next_action ilike '%' || v_search || '%'
             or r.blocker ilike '%' || v_search || '%')
      order by r.report_date desc, r.created_at desc
      limit 3000
    ) r), '[]'::jsonb);
end $$;

-- The dashboard's figures for a period, all calculated from the reports I
-- may see (optionally one department):
--   status: {"completed": 12, ...}
--   departments: [{id, name, activities, completed, open, blocked,
--                  escalated, people, outputs: {key: total}}]
--   compliance: [{id, full_name, department_id, department_name,
--                 days_submitted, entries, last_date, submitted_today}]
--   working_days: Monday–Friday in the period, up to today
--   overdue / attention: open items past their due date, and blocked or
--                        escalated ones (any date; newest 200)
create or replace function public.report_summary(
  p_token text, p_from date, p_to date, p_department bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
  today date := private.today();
begin
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', today,
    'working_days', (
      select count(*) from generate_series(p_from, least(p_to, today), interval '1 day') d
      where extract(isodow from d) < 6),
    'status', coalesce((
      select jsonb_object_agg(status, n) from (
        select r.status, count(*) n from public.activity_reports r
        where private.can_see_report(me, r.user_id, r.department_id)
          and r.report_date between p_from and p_to
          and (p_department is null or r.department_id = p_department)
        group by r.status) s), '{}'::jsonb),
    'departments', coalesce((
      select jsonb_agg(x order by x->>'position', x->>'name') from (
        select jsonb_build_object(
          'id', d.id, 'name', d.name, 'position', lpad(d.position::text, 6, '0'),
          'activities', count(r.id),
          'completed', count(r.id) filter (where r.status = 'completed'),
          'open', count(r.id) filter (where r.status <> 'completed'),
          'blocked', count(r.id) filter (where r.status = 'blocked'),
          'escalated', count(r.id) filter (where r.status = 'escalated'),
          'people', count(distinct r.user_id),
          'outputs', coalesce((
            select jsonb_object_agg(k, total) from (
              select o.key k, sum((o.value #>> '{}')::int) total
              from public.activity_reports r2, jsonb_each(r2.outputs) o
              where r2.department_id = d.id
                and private.can_see_report(me, r2.user_id, r2.department_id)
                and r2.report_date between p_from and p_to
              group by o.key) t), '{}'::jsonb)) x
        from public.departments d
        left join public.activity_reports r
          on r.department_id = d.id
         and r.report_date between p_from and p_to
         and private.can_see_report(me, r.user_id, r.department_id)
        where (p_department is null or d.id = p_department)
          and (scope = 'all' or d.id = my_dept)
          and (d.active or r.id is not null)
        group by d.id) s), '[]'::jsonb),
    'compliance', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id, 'full_name', u.full_name,
        'department_id', u.department_id,
        'department_name', (select name from public.departments where id = u.department_id),
        'days_submitted', (select count(distinct r.report_date) from public.activity_reports r
                           where r.user_id = u.id and r.report_date between p_from and p_to),
        'entries', (select count(*) from public.activity_reports r
                    where r.user_id = u.id and r.report_date between p_from and p_to),
        'last_date', (select max(r.report_date) from public.activity_reports r where r.user_id = u.id),
        'submitted_today', exists (select 1 from public.activity_reports r
                                   where r.user_id = u.id and r.report_date = today))
        order by lower(u.full_name))
      from private.app_users u
      where u.active and u.department_id is not null
        and (p_department is null or u.department_id = p_department)
        and (scope = 'all'
             or (scope = 'department' and u.department_id = my_dept)
             or u.id = me)), '[]'::jsonb),
    'overdue', coalesce((
      select jsonb_agg(private.report_json(r) order by r.due_date, r.id) from (
        select * from public.activity_reports r
        where r.status <> 'completed' and r.due_date < today
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
        order by r.due_date limit 200) r), '[]'::jsonb),
    'attention', coalesce((
      select jsonb_agg(private.report_json(r) order by r.report_date desc, r.id desc) from (
        select * from public.activity_reports r
        where r.status in ('blocked', 'escalated')
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
        order by r.report_date desc limit 200) r), '[]'::jsonb)
  );
end $$;

-- The audit trail of one report I may see.
create or replace function public.report_history(p_token text, p_report bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  owner bigint;
  dept bigint;
begin
  select coalesce(r.user_id, (c.before->>'user_id')::bigint),
         coalesce(r.department_id, (c.before->>'department_id')::bigint)
    into owner, dept
    from public.activity_changes c
    left join public.activity_reports r on r.id = c.report_id
    where c.report_id = p_report
    order by c.id desc limit 1;
  if owner is null or not private.can_see_report(me, owner, dept) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', c.action, 'changed_at', c.changed_at,
      'changed_by', (select full_name from private.app_users where id = c.changed_by),
      'before', c.before, 'after', c.after) order by c.id)
    from public.activity_changes c where c.report_id = p_report), '[]'::jsonb);
end $$;

-- ---- Writing -----------------------------------------------------------------

-- Adds (no "id") or changes one of MY reports (an admin may change anyone's).
-- {"id", "report_date", "description", "reference", "outputs", "status",
--  "next_action", "blocker", "priority", "due_date"}
-- The person and department come from the sign-in, not from the request.
-- Dates: not in the future; up to 7 days back (admins and managers: any).
-- An open item (anything but completed) needs a due / follow-up date.
create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_date date := coalesce(nullif(p_report->>'report_date', '')::date, private.today());
  v_status text := coalesce(nullif(p_report->>'status', ''), 'completed');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_dept bigint;
begin
  select * into u from private.app_users where id = me;
  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if before.user_id <> me and u.role <> 'admin' then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_dept := before.department_id;
  else
    v_dept := u.department_id;
    if v_dept is null then
      raise exception 'no_department' using errcode = '22023';
    end if;
  end if;
  if v_date > private.today() then
    raise exception 'future_date' using errcode = '22023';
  end if;
  if v_date < private.today() - 7 and private.report_scope(me) <> 'all'
     and (rid is null or v_date <> before.report_date) then
    raise exception 'date_too_old' using errcode = '22023';
  end if;
  if v_status <> 'completed' and v_due is null then
    raise exception 'due_date_required' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_report->>'description', ''))) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date, description,
        reference, outputs, status, next_action, blocker, priority, due_date)
      values (me, v_dept, v_date, trim(p_report->>'description'),
        trim(coalesce(p_report->>'reference', '')),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, trim(coalesce(p_report->>'next_action', '')),
        trim(coalesce(p_report->>'blocker', '')),
        coalesce(nullif(p_report->>'priority', ''), 'medium'), v_due)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
  else
    update public.activity_reports set
        report_date = v_date,
        description = trim(p_report->>'description'),
        reference = trim(coalesce(p_report->>'reference', '')),
        outputs = private.clean_outputs(p_report->'outputs', v_dept),
        status = v_status,
        next_action = trim(coalesce(p_report->>'next_action', '')),
        blocker = trim(coalesce(p_report->>'blocker', '')),
        priority = coalesce(nullif(p_report->>'priority', ''), 'medium'),
        due_date = v_due,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, 'edited', to_jsonb(before), to_jsonb(saved));
  end if;
  return private.report_json(saved);
end $$;

-- Removes one of MY reports (an admin may remove anyone's). Kept in the
-- audit trail.
create or replace function public.report_delete(p_token text, p_report bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then return; end if;
  if r.user_id <> me and (select role from private.app_users where id = me) <> 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.activity_reports where id = p_report;
  insert into public.activity_changes (report_id, changed_by, action, before)
    values (p_report, me, 'deleted', to_jsonb(r));
end $$;

-- ---- Admin: departments and people -------------------------------------------

-- Creates (no "id") or changes a department:
-- {"id", "name", "outputs": [{"key", "label"}], "active", "position"}
create or replace function public.admin_save_department(p_token text, p_department jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  did bigint := nullif(p_department->>'id', '')::bigint;
  v_name text := trim(coalesce(p_department->>'name', ''));
  v_outputs jsonb := coalesce(p_department->'outputs', '[]'::jsonb);
  saved public.departments;
begin
  perform private.check_token(p_token);
  if length(v_name) = 0 then
    raise exception 'bad_name' using errcode = '22023';
  end if;
  if jsonb_typeof(v_outputs) <> 'array' or exists (
      select 1 from jsonb_array_elements(v_outputs) o
      where coalesce(o->>'key', '') !~ '^[a-z0-9_]{1,40}$'
         or length(trim(coalesce(o->>'label', ''))) = 0) then
    raise exception 'bad_outputs' using errcode = '22023';
  end if;
  if exists (select 1 from public.departments
             where lower(name) = lower(v_name) and id is distinct from did) then
    raise exception 'name_taken' using errcode = '23505';
  end if;
  if did is null then
    insert into public.departments (name, outputs, active, position)
      values (v_name, v_outputs, coalesce((p_department->>'active')::boolean, true),
              coalesce((p_department->>'position')::int,
                       (select coalesce(max(position), 0) + 1 from public.departments)))
      returning * into saved;
  else
    update public.departments set
        name = v_name, outputs = v_outputs,
        active = coalesce((p_department->>'active')::boolean, active),
        position = coalesce((p_department->>'position')::int, position)
      where id = did
      returning * into saved;
    if saved.id is null then
      raise exception 'unknown_department' using errcode = '22023';
    end if;
  end if;
  return to_jsonb(saved);
end $$;

-- Accounts now also have a department and report access (employee, head,
-- manager). Same rules as before otherwise.
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
  v_dept bigint := nullif(p_user->>'department_id', '')::bigint;
  v_access text := coalesce(nullif(p_user->>'report_access', ''), 'employee');
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
  if v_access not in ('employee', 'head', 'manager') then
    raise exception 'bad_access' using errcode = '22023';
  end if;
  if v_dept is not null and not exists (select 1 from public.departments where id = v_dept) then
    raise exception 'unknown_department' using errcode = '22023';
  end if;
  if exists (select 1 from private.app_users
             where username = v_name and id is distinct from uid) then
    raise exception 'username_taken' using errcode = '23505';
  end if;
  if uid is null then
    perform private.check_password(p_user->>'password');
    insert into private.app_users (username, full_name, role, staff_id, hash, active,
        must_change, department_id, report_access)
      values (v_name, v_full, v_role, v_staff,
              extensions.crypt(p_user->>'password', extensions.gen_salt('bf', 10)),
              v_active, true, v_dept, v_access)
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
        staff_id = v_staff, active = v_active, updated_at = now(),
        department_id = case when p_user ? 'department_id' then v_dept else department_id end,
        report_access = case when p_user ? 'report_access' then v_access else report_access end
    where id = uid;
  if not exists (select 1 from private.app_users where role = 'admin' and active) then
    raise exception 'last_admin' using errcode = '42501';
  end if;
  if before.role <> v_role or (before.active and not v_active) then
    delete from private.admin_tokens where user_id = uid;
  end if;
  return private.user_json(uid);
end $$;

-- ---- Access ------------------------------------------------------------------

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.reports_meta(text), public.report_list(text, jsonb),
  public.report_summary(text, date, date, bigint), public.report_history(text, bigint),
  public.report_save(text, jsonb), public.report_delete(text, bigint),
  public.admin_save_department(text, jsonb) from public;
grant execute on function public.reports_meta(text), public.report_list(text, jsonb),
  public.report_summary(text, date, date, bigint), public.report_history(text, bigint),
  public.report_save(text, jsonb), public.report_delete(text, bigint),
  public.admin_save_department(text, jsonb) to anon, authenticated;

-- ===== Fixes from review (2026-11-09) =====
-- Also in supabase/migrations/20261109140000_review_fixes.sql.

-- 1. Outputs: the number check now guards the conversion itself (PostgreSQL
--    may evaluate WHERE conditions in any order, so a value like "3 files"
--    could fail the whole save instead of being left out). Keys a report
--    already had stay allowed ([p_keep]), so editing an old report doesn't
--    lose a count whose output the admin has since renamed or removed.
drop function if exists private.clean_outputs(jsonb, bigint);
create or replace function private.clean_outputs(
  p_outputs jsonb, p_department bigint, p_keep jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(e.key, least(e.n, 100000)::int), '{}'::jsonb)
  from (
    select o.key,
           case when (o.value #>> '{}') ~ '^\s*[0-9]{1,9}(\.[0-9]+)?\s*$'
                then round((o.value #>> '{}')::numeric) end as n
    from jsonb_each(case when jsonb_typeof(p_outputs) = 'object'
                         then p_outputs else '{}'::jsonb end) o
  ) e
  where e.n is not null and e.n > 0
    and (e.key in (select x->>'key' from public.departments d,
                   jsonb_array_elements(d.outputs) x where d.id = p_department)
         or (jsonb_typeof(p_keep) = 'object' and p_keep ? e.key));
$$;

-- report_save: same as before, but an edit keeps the report's existing
-- output keys.
create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_date date := coalesce(nullif(p_report->>'report_date', '')::date, private.today());
  v_status text := coalesce(nullif(p_report->>'status', ''), 'completed');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_dept bigint;
begin
  select * into u from private.app_users where id = me;
  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if before.user_id <> me and u.role <> 'admin' then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_dept := before.department_id;
  else
    v_dept := u.department_id;
    if v_dept is null then
      raise exception 'no_department' using errcode = '22023';
    end if;
  end if;
  if v_date > private.today() then
    raise exception 'future_date' using errcode = '22023';
  end if;
  if v_date < private.today() - 7 and private.report_scope(me) <> 'all'
     and (rid is null or v_date <> before.report_date) then
    raise exception 'date_too_old' using errcode = '22023';
  end if;
  if v_status <> 'completed' and v_due is null then
    raise exception 'due_date_required' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_report->>'description', ''))) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date, description,
        reference, outputs, status, next_action, blocker, priority, due_date)
      values (me, v_dept, v_date, trim(p_report->>'description'),
        trim(coalesce(p_report->>'reference', '')),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, trim(coalesce(p_report->>'next_action', '')),
        trim(coalesce(p_report->>'blocker', '')),
        coalesce(nullif(p_report->>'priority', ''), 'medium'), v_due)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
  else
    update public.activity_reports set
        report_date = v_date,
        description = trim(p_report->>'description'),
        reference = trim(coalesce(p_report->>'reference', '')),
        outputs = private.clean_outputs(p_report->'outputs', v_dept, before.outputs),
        status = v_status,
        next_action = trim(coalesce(p_report->>'next_action', '')),
        blocker = trim(coalesce(p_report->>'blocker', '')),
        priority = coalesce(nullif(p_report->>'priority', ''), 'medium'),
        due_date = v_due,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, 'edited', to_jsonb(before), to_jsonb(saved));
  end if;
  return private.report_json(saved);
end $$;

-- 2. The dashboard's figures can be for one person (p_user), so a Staff
--    Activity Report's totals, departments, compliance and attention lists
--    are that person's, not everyone's.
drop function if exists public.report_summary(text, date, date, bigint);
create or replace function public.report_summary(
  p_token text, p_from date, p_to date, p_department bigint, p_user bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
  today date := private.today();
begin
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', today,
    'working_days', (
      select count(*) from generate_series(p_from, least(p_to, today), interval '1 day') d
      where extract(isodow from d) < 6),
    'status', coalesce((
      select jsonb_object_agg(status, n) from (
        select r.status, count(*) n from public.activity_reports r
        where private.can_see_report(me, r.user_id, r.department_id)
          and r.report_date between p_from and p_to
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        group by r.status) s), '{}'::jsonb),
    'departments', coalesce((
      select jsonb_agg(x order by x->>'position', x->>'name') from (
        select jsonb_build_object(
          'id', d.id, 'name', d.name, 'position', lpad(d.position::text, 6, '0'),
          'activities', count(r.id),
          'completed', count(r.id) filter (where r.status = 'completed'),
          'open', count(r.id) filter (where r.status <> 'completed'),
          'blocked', count(r.id) filter (where r.status = 'blocked'),
          'escalated', count(r.id) filter (where r.status = 'escalated'),
          'people', count(distinct r.user_id),
          'outputs', coalesce((
            select jsonb_object_agg(k, total) from (
              select o.key k, sum((o.value #>> '{}')::int) total
              from public.activity_reports r2, jsonb_each(r2.outputs) o
              where r2.department_id = d.id
                and private.can_see_report(me, r2.user_id, r2.department_id)
                and r2.report_date between p_from and p_to
                and (p_user is null or r2.user_id = p_user)
              group by o.key) t), '{}'::jsonb)) x
        from public.departments d
        left join public.activity_reports r
          on r.department_id = d.id
         and r.report_date between p_from and p_to
         and private.can_see_report(me, r.user_id, r.department_id)
         and (p_user is null or r.user_id = p_user)
        where (p_department is null or d.id = p_department)
          and (scope = 'all' or d.id = my_dept)
          and (p_user is null
               or d.id = (select department_id from private.app_users where id = p_user)
               or r.id is not null)
          and (d.active or r.id is not null)
        group by d.id) s), '[]'::jsonb),
    'compliance', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id, 'full_name', u.full_name,
        'department_id', u.department_id,
        'department_name', (select name from public.departments where id = u.department_id),
        'days_submitted', (select count(distinct r.report_date) from public.activity_reports r
                           where r.user_id = u.id and r.report_date between p_from and p_to),
        'entries', (select count(*) from public.activity_reports r
                    where r.user_id = u.id and r.report_date between p_from and p_to),
        'last_date', (select max(r.report_date) from public.activity_reports r where r.user_id = u.id),
        'submitted_today', exists (select 1 from public.activity_reports r
                                   where r.user_id = u.id and r.report_date = today))
        order by lower(u.full_name))
      from private.app_users u
      where u.active and u.department_id is not null
        and (p_department is null or u.department_id = p_department)
        and (p_user is null or u.id = p_user)
        and (scope = 'all'
             or (scope = 'department' and u.department_id = my_dept)
             or u.id = me)), '[]'::jsonb),
    'overdue', coalesce((
      select jsonb_agg(private.report_json(r) order by r.due_date, r.id) from (
        select * from public.activity_reports r
        where r.status <> 'completed' and r.due_date < today
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.due_date limit 200) r), '[]'::jsonb),
    'attention', coalesce((
      select jsonb_agg(private.report_json(r) order by r.report_date desc, r.id desc) from (
        select * from public.activity_reports r
        where r.status in ('blocked', 'escalated')
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.report_date desc limit 200) r), '[]'::jsonb)
  );
end $$;

-- 3. The old shared-profile functions (still used by old app builds until
--    every device is updated) signed out tokens by role, which now includes
--    personal accounts. They only touch the old shared-profile tokens now.
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
  delete from private.admin_tokens where role = p_role and user_id is null;
end $$;

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
    where role = 'admin' and user_id is null
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

create or replace function public.admin_recover(p_code text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  stored text;
  code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(coalesce(p_new, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  if length(code) = 16 then
    code := substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' ||
            substr(code, 9, 4) || '-' || substr(code, 13, 4);
  end if;
  select recovery_hash into stored from private.admin_secret where id = 1;
  if stored is null or extensions.crypt(code, stored) <> stored then
    perform pg_sleep(1);
    raise exception 'wrong_recovery_code' using errcode = '28000';
  end if;
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        recovery_hash = null,
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens where user_id is null;
  return private.new_token();
end $$;

-- ---- Access ------------------------------------------------------------------

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.report_summary(text, date, date, bigint, bigint),
  public.report_save(text, jsonb), public.admin_set_profile_password(text, text, text),
  public.admin_set_password(text, text), public.admin_recover(text, text) from public;
grant execute on function public.report_summary(text, date, date, bigint, bigint),
  public.report_save(text, jsonb), public.admin_set_profile_password(text, text, text),
  public.admin_set_password(text, text), public.admin_recover(text, text) to anon, authenticated;

-- ===== Deleting accounts (2026-11-09) =====
-- Also in supabase/migrations/20261109160000_delete_users.sql.
-- An admin can delete an account. Someone with daily reports can only be
-- deleted together with their reports (asked for explicitly); switching the
-- account off is the way to keep their history. Nobody can delete their own
-- account or the last admin. Each deleted report is noted in the audit
-- trail as deleted by the admin.

-- The audit trail outlives the people in it.
alter table public.activity_changes
  drop constraint if exists activity_changes_changed_by_fkey;
alter table public.activity_changes
  add constraint activity_changes_changed_by_fkey
  foreign key (changed_by) references private.app_users(id) on delete set null;

-- Deletes account [p_user_id]. With daily reports and [p_with_reports]
-- false: refused with 'has_reports:<count>' so the admin can choose.
create or replace function public.admin_delete_user(
  p_token text, p_user_id bigint, p_with_reports boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me bigint;
  target private.app_users;
  n integer;
begin
  perform private.check_token(p_token);
  begin
    me := private.token_user(p_token);
  exception when others then
    me := null; -- the old shared admin profile
  end;
  select * into target from private.app_users where id = p_user_id for update;
  if target.id is null then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  if target.id = me then
    raise exception 'own_account' using errcode = '42501';
  end if;
  if target.role = 'admin' and target.active and not exists (
      select 1 from private.app_users
      where role = 'admin' and active and id <> target.id) then
    raise exception 'last_admin' using errcode = '42501';
  end if;
  select count(*) into n from public.activity_reports where user_id = target.id;
  if n > 0 and not coalesce(p_with_reports, false) then
    raise exception 'has_reports:%', n using errcode = '23503';
  end if;
  insert into public.activity_changes (report_id, changed_by, action, before)
    select r.id, me, 'deleted', to_jsonb(r)
    from public.activity_reports r where r.user_id = target.id;
  delete from public.activity_reports where user_id = target.id;
  -- Their sign-ins go with the account (admin_tokens.user_id cascades).
  delete from private.app_users where id = target.id;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.admin_delete_user(text, bigint, boolean) from public;
grant execute on function public.admin_delete_user(text, bigint, boolean) to anon, authenticated;

-- ===== Daily reports for the team (2026-11-09) =====
-- Also in supabase/migrations/20261109170000_team_features.sql.
-- 1. Assigned tasks: a department head, the Operations Manager or an admin
--    can give someone a task (a report in that person's name, marked with
--    who assigned it). The person updates it like their own work; whoever
--    assigned it can still change or remove it.
-- 2. Comments on a report: anyone who can see it (the writer, their head,
--    managers, admins, the director) can comment, e.g. to ask for
--    clarification or give feedback.

alter table public.activity_reports
  add column if not exists assigned_by bigint references private.app_users(id) on delete set null;

create table if not exists public.report_comments (
  id         bigint generated always as identity primary key,
  report_id  bigint not null references public.activity_reports(id) on delete cascade,
  user_id    bigint references private.app_users(id) on delete set null,
  body       text not null check (length(trim(body)) > 0 and length(body) <= 1000),
  created_at timestamptz not null default now()
);
create index if not exists report_comments_report_idx on public.report_comments(report_id);
alter table public.report_comments enable row level security;
revoke all on public.report_comments from anon, authenticated;

-- Reports now say who assigned them (if anyone) and how many comments
-- they have.
create or replace function private.report_json(r public.activity_reports)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(r) || jsonb_build_object(
    'user_name', (select full_name from private.app_users where id = r.user_id),
    'department_name', (select name from public.departments where id = r.department_id),
    'assigned_by_name', (select full_name from private.app_users where id = r.assigned_by),
    'comment_count', (select count(*) from public.report_comments c where c.report_id = r.id));
$$;

-- May [p_user] change or remove report [r]: its writer, whoever assigned
-- it, or an admin.
create or replace function private.can_change_report(p_user bigint, r public.activity_reports)
returns boolean language sql stable security definer set search_path = '' as $$
  select r.user_id = p_user
      or r.assigned_by = p_user
      or (select role from private.app_users where id = p_user) = 'admin';
$$;

-- ---- Saving (adds assigning) -------------------------------------------------

-- As before, plus: {"user_id": N} on a NEW report assigns it to person N
-- (department heads: people in their department; managers, admins and the
-- director: anyone with a department). An assigned task needs a due date.
create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  owner private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  v_for bigint := nullif(p_report->>'user_id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_date date := coalesce(nullif(p_report->>'report_date', '')::date, private.today());
  v_status text := coalesce(nullif(p_report->>'status', ''), 'completed');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_dept bigint;
  v_assigned bigint;
begin
  select * into u from private.app_users where id = me;
  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if not private.can_change_report(me, before) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_dept := before.department_id;
  elsif v_for is not null and v_for <> me then
    -- Assigning a task to someone else.
    select * into owner from private.app_users where id = v_for and active;
    if owner.id is null then
      raise exception 'unknown_user' using errcode = '22023';
    end if;
    if owner.department_id is null then
      raise exception 'no_department' using errcode = '22023';
    end if;
    if private.report_scope(me) = 'own'
       or not private.can_see_report(me, owner.id, owner.department_id) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    if v_due is null then
      raise exception 'due_date_required' using errcode = '22023';
    end if;
    v_dept := owner.department_id;
    v_assigned := me;
  else
    v_dept := u.department_id;
    if v_dept is null then
      raise exception 'no_department' using errcode = '22023';
    end if;
  end if;
  if v_date > private.today() then
    raise exception 'future_date' using errcode = '22023';
  end if;
  if v_date < private.today() - 7 and private.report_scope(me) <> 'all'
     and (rid is null or v_date <> before.report_date) then
    raise exception 'date_too_old' using errcode = '22023';
  end if;
  if v_status <> 'completed' and v_due is null then
    raise exception 'due_date_required' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_report->>'description', ''))) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date, description,
        reference, outputs, status, next_action, blocker, priority, due_date, assigned_by)
      values (coalesce(owner.id, me), v_dept, v_date, trim(p_report->>'description'),
        trim(coalesce(p_report->>'reference', '')),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, trim(coalesce(p_report->>'next_action', '')),
        trim(coalesce(p_report->>'blocker', '')),
        coalesce(nullif(p_report->>'priority', ''), 'medium'), v_due, v_assigned)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
  else
    update public.activity_reports set
        report_date = v_date,
        description = trim(p_report->>'description'),
        reference = trim(coalesce(p_report->>'reference', '')),
        outputs = private.clean_outputs(p_report->'outputs', v_dept, before.outputs),
        status = v_status,
        next_action = trim(coalesce(p_report->>'next_action', '')),
        blocker = trim(coalesce(p_report->>'blocker', '')),
        priority = coalesce(nullif(p_report->>'priority', ''), 'medium'),
        due_date = v_due,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, 'edited', to_jsonb(before), to_jsonb(saved));
  end if;
  return private.report_json(saved);
end $$;

-- Removing: the writer, whoever assigned it, or an admin.
create or replace function public.report_delete(p_token text, p_report bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then return; end if;
  if not private.can_change_report(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.activity_reports where id = p_report;
  insert into public.activity_changes (report_id, changed_by, action, before)
    values (p_report, me, 'deleted', to_jsonb(r));
end $$;

-- ---- Comments ------------------------------------------------------------------

-- The comments on a report I may see, oldest first.
create or replace function public.report_comments(p_token text, p_report bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null or not private.can_see_report(me, r.user_id, r.department_id) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'body', c.body, 'created_at', c.created_at,
      'user_id', c.user_id,
      'user_name', (select full_name from private.app_users where id = c.user_id))
      order by c.id)
    from public.report_comments c where c.report_id = p_report), '[]'::jsonb);
end $$;

-- Adds a comment to a report I may see. Returns all its comments.
create or replace function public.report_comment_add(p_token text, p_report bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_see_report(me, r.user_id, r.department_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_body, ''))) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  insert into public.report_comments (report_id, user_id, body)
    values (p_report, me, left(trim(p_body), 1000));
  return public.report_comments(p_token, p_report);
end $$;

-- Removes one of MY comments (admins: anyone's).
create or replace function public.report_comment_delete(p_token text, p_comment bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
begin
  delete from public.report_comments c
  where c.id = p_comment
    and (c.user_id = me or (select role from private.app_users where id = me) = 'admin');
end $$;

-- ---- Access ------------------------------------------------------------------

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.report_save(text, jsonb), public.report_delete(text, bigint),
  public.report_comments(text, bigint), public.report_comment_add(text, bigint, text),
  public.report_comment_delete(text, bigint) from public;
grant execute on function public.report_save(text, jsonb), public.report_delete(text, bigint),
  public.report_comments(text, bigint), public.report_comment_add(text, bigint, text),
  public.report_comment_delete(text, bigint) to anon, authenticated;

-- ===== Applications from Airtable (2026-11-10) =====
-- The online database reads the Airtable "Applications Tracker" itself, so
-- nobody has to export and upload a CSV. The token is in the Vault
-- (secret "airtable_token", read-only). Airtable's free plan allows 1,000
-- API calls a month per workspace, so:
--   * every 30 minutes in working hours only what changed is read
--     (one call, usually);
--   * every night everything is read (about one call per 100 records),
--     which also catches deleted records;
--   * the calls are counted, and the schedule slows down and then stops
--     before the limit (the CSV upload in the app still works).
-- What changed is noted exactly as a CSV upload notes it
-- (application_imports, application_changes), with the same keys.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

-- Calls per month (Kenya time).
create table if not exists private.airtable_usage (
  month date primary key,
  calls integer not null default 0
);

-- What to read, and which Airtable field is which column. Fields are by ID,
-- so renaming a column in Airtable doesn't break anything.
create table if not exists private.airtable_config (
  id         integer primary key default 1 check (id = 1),
  base_id    text not null,
  table_id   text not null,
  view_id    text not null,
  fields     jsonb not null,
  enabled    boolean not null default false   -- switched on once checked
);
insert into private.airtable_config (id, base_id, table_id, view_id, fields)
values (1, 'appIohpumIL9A0S6I', 'tbl70dKK7cS4qg2nv', 'viwWTcXq51ZU9ogLo',
  '{"student":"fldqRDr6bYHemY5Jp","rto":"fldmOOpIKYYmotxLq",
    "country":"flduT37ZU1qT2oxfj","doc_date":"fld9fk1b4KS3m29Da",
    "app_date":"fldTwdFJdAb6mG5Xj","offer_date":"fldfM6DHHcxFbgG7A",
    "coe_date":"fldWX9dyqMPJRccg5","status":"fldaJhoOjVZJTuZ9d",
    "assignee":"fldD5mwyrmAEkISGy","todo":"fldx7eZYxaUfePGnQ",
    "follow_up":"fldI6vaEWxJOSublh"}')
on conflict (id) do nothing;

-- How the sync is doing.
create table if not exists private.airtable_state (
  id            integer primary key default 1 check (id = 1),
  cursor_at     timestamptz,          -- changes after this are read next
  last_run_at   timestamptz,
  last_ok_at    timestamptz,
  last_full_at  timestamptz,
  last_kind     text,
  last_result   jsonb,
  last_error    text,
  last_error_at timestamptz
);
insert into private.airtable_state (id) values (1) on conflict (id) do nothing;

-- The Airtable records as last read, in the view's order.
create table if not exists private.airtable_records (
  rec_id    text primary key,
  fields    jsonb not null,
  position  integer not null,
  read_at   timestamptz not null default now()
);

-- GET https://api.airtable.com/v0/<path> with the Vault token; counts the
-- call. Returns {status, body}.
create or replace function private.airtable_get(p_path text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_resp extensions.http_response;
  v_month date := date_trunc('month', now() at time zone 'Africa/Nairobi')::date;
begin
  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'airtable_token' limit 1;
  if v_token is null then
    raise exception 'no_airtable_token' using errcode = 'P0001';
  end if;
  insert into private.airtable_usage as u (month, calls) values (v_month, 1)
    on conflict (month) do update set calls = u.calls + 1;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '30');
  select * into v_resp from extensions.http((
    'GET',
    'https://api.airtable.com/v0/' || p_path,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    null, null)::extensions.http_request);
  return jsonb_build_object(
    'status', v_resp.status,
    'body', case when v_resp.content is null or v_resp.content = '' then null
                 else v_resp.content::jsonb end);
end $$;

create or replace function private.airtable_calls_this_month()
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select calls from private.airtable_usage
    where month = date_trunc('month', now() at time zone 'Africa/Nairobi')::date), 0);
$$;

-- Kenya local time as the app writes it ("2026-11-10T14:06:47.865654").
create or replace function private.kenya_now_text()
returns text language sql stable set search_path = '' as $$
  select to_char(now() at time zone 'Africa/Nairobi', 'YYYY-MM-DD"T"HH24:MI:SS.US');
$$;

-- Trims, and (unless p_keep_lines) folds runs of spaces / line breaks into
-- one space — the CSV upload's clean-up.
create or replace function private.airtable_text(p_value jsonb, p_keep_lines boolean default false)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then ''
    when p_keep_lines then regexp_replace(
      case jsonb_typeof(p_value) when 'string' then p_value #>> '{}' else p_value::text end,
      '^\s+|\s+$', '', 'g')
    else btrim(regexp_replace(
      case jsonb_typeof(p_value)
        when 'string' then p_value #>> '{}'
        -- a list (several options, linked names): joined with commas
        when 'array' then (select string_agg(coalesce(e->>'name', e #>> '{}'), ', ')
                             from jsonb_array_elements(p_value) e)
        when 'object' then coalesce(p_value->>'name', p_value::text)
        else p_value #>> '{}' end,
      '\s+', ' ', 'g'))
  end;
$$;

-- "2026-02-02" (or a date-time) → "2026-02-02"; null when empty or odd.
create or replace function private.airtable_date(p_value jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare s text := p_value #>> '{}';
begin
  if s is null or s !~ '^\d{4}-\d{2}-\d{2}' then return null; end if;
  return to_char(left(s, 10)::date, 'YYYY-MM-DD');
exception when others then
  return null;
end $$;

-- Reads Airtable into private.airtable_records. p_full: everything (and
-- drops records no longer there); otherwise only records changed since the
-- last read. Returns {calls, read}.
create or replace function private.airtable_fetch(p_full boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  s private.airtable_state;
  v_started timestamptz := now();
  v_path text;
  v_offset text;
  v_resp jsonb;
  v_status int;
  v_calls int := 0;
  v_read int := 0;
  v_pos int := 0;
  v_next_pos int;
  v_fields text := '';
  v_seen text[] := '{}';
  rec jsonb;
  f text;
begin
  select * into c from private.airtable_config where id = 1;
  select * into s from private.airtable_state where id = 1;
  for f in select value from jsonb_each_text(c.fields) loop
    v_fields := v_fields || '&fields%5B%5D=' || f;
  end loop;
  if not p_full and s.cursor_at is null then
    p_full := true;                    -- never read: read everything
  end if;
  select coalesce(max(position), -1) + 1 into v_next_pos from private.airtable_records;

  loop
    v_path := c.base_id || '/' || c.table_id || '?view=' || c.view_id
      || '&pageSize=100&returnFieldsByFieldId=true' || v_fields;
    if not p_full then
      -- A minute's overlap, so a change made during the last read is caught.
      v_path := v_path || '&filterByFormula=' || extensions.urlencode(format(
        'IS_AFTER(LAST_MODIFIED_TIME(), ''%s'')',
        to_char((s.cursor_at - interval '1 minute') at time zone 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.000"Z"')));
    end if;
    if v_offset is not null then
      v_path := v_path || '&offset=' || extensions.urlencode(v_offset);
    end if;
    v_resp := private.airtable_get(v_path);
    v_calls := v_calls + 1;
    v_status := (v_resp->>'status')::int;
    if v_status <> 200 then
      raise exception '%', case
        when v_status in (401, 403) then 'airtable_token_rejected'
        when v_status = 404 then 'airtable_not_found'
        when v_status = 429 then 'airtable_limit'
        else 'airtable_error_' || v_status end
        using errcode = 'P0001',
              detail = coalesce(v_resp->'body'->'error'->>'message',
                                v_resp->'body'->>'error', '');
    end if;
    for rec in select value from jsonb_array_elements(v_resp->'body'->'records') loop
      v_read := v_read + 1;
      v_seen := v_seen || (rec->>'id');
      if p_full then
        insert into private.airtable_records as r (rec_id, fields, position, read_at)
          values (rec->>'id', coalesce(rec->'fields', '{}'), v_pos, v_started)
          on conflict (rec_id) do update
            set fields = excluded.fields, position = excluded.position, read_at = excluded.read_at;
        v_pos := v_pos + 1;
      else
        -- Changed records keep their place; new ones go at the end (where
        -- Airtable puts them) until the night's full read.
        insert into private.airtable_records as r (rec_id, fields, position, read_at)
          values (rec->>'id', coalesce(rec->'fields', '{}'), v_next_pos, v_started)
          on conflict (rec_id) do update
            set fields = excluded.fields, read_at = excluded.read_at;
        if found then v_next_pos := v_next_pos + 1; end if;
      end if;
    end loop;
    v_offset := v_resp->'body'->>'offset';
    exit when v_offset is null;
    if v_calls >= 20 then              -- 2,000 records: something's wrong
      raise exception 'airtable_too_many_pages' using errcode = 'P0001';
    end if;
    perform pg_sleep(0.25);            -- Airtable: at most 5 calls a second
  end loop;

  if p_full then
    delete from private.airtable_records where not (rec_id = any (v_seen));
  end if;
  update private.airtable_state
    set cursor_at = v_started,
        last_full_at = case when p_full then v_started else last_full_at end
    where id = 1;
  return jsonb_build_object('calls', v_calls, 'read', v_read, 'full', p_full);
end $$;

-- A new row id like the app's (microseconds), above every id in use.
create or replace function private.applications_next_id()
returns bigint language sql volatile security definer set search_path = '' as $$
  select greatest(
    (extract(epoch from clock_timestamp()) * 1000000)::bigint,
    coalesce((select max(id) from public.applications), 0) + 1,
    coalesce((select max(id) from public.application_imports), 0) + 1,
    coalesce((select max(id) from public.application_changes), 0) + 1);
$$;

-- Brings public.applications in line with private.airtable_records, the way
-- the app's CSV upload does (ApplicationRepository.importCsv): same keys,
-- same "what changed" notes. Writes an import entry only when something
-- changed. Returns {total, added, changed, removed, first}.
create or replace function private.applications_apply(p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  v_now text := private.kenya_now_text();
  v_first boolean;
  v_total int;
  v_added int;
  v_changed int;
  v_removed int;
  v_import bigint;
  v_base bigint;
  m record;
  fields text[] := array['rto','country','doc_date','app_date','offer_date',
    'coe_date','status','assignee','todo','follow_up'];
begin
  select * into c from private.airtable_config where id = 1;
  perform set_config('client_min_messages', 'warning', true);
  drop table if exists _in, _diff, _new, _gone;
  v_first := not exists (select 1 from public.applications)
         and not exists (select 1 from public.application_imports);

  -- The incoming applications, cleaned like the CSV.
  create temp table _in on commit drop as
  with raw as (
    select r.position, r.rec_id,
      private.airtable_text(r.fields->(c.fields->>'student')) as student,
      private.airtable_text(r.fields->(c.fields->>'rto')) as rto,
      private.airtable_text(r.fields->(c.fields->>'country')) as country,
      private.airtable_date(r.fields->(c.fields->>'doc_date')) as doc_date,
      private.airtable_date(r.fields->(c.fields->>'app_date')) as app_date,
      private.airtable_date(r.fields->(c.fields->>'offer_date')) as offer_date,
      private.airtable_date(r.fields->(c.fields->>'coe_date')) as coe_date,
      private.airtable_text(r.fields->(c.fields->>'status')) as status,
      private.airtable_text(r.fields->(c.fields->>'assignee')) as assignee,
      private.airtable_text(r.fields->(c.fields->>'todo'), true) as todo,
      private.airtable_text(r.fields->(c.fields->>'follow_up'), true) as follow_up
    from private.airtable_records r
  ), kept as (
    select raw.*,
      (row_number() over (order by position, rec_id) - 1)::int as pos,
      lower(student) as base,
      lower(concat_ws(' · ', nullif(rto, ''), nullif(country, ''))) as place
    from raw where student <> ''
  ), places as (
    select base, count(distinct place) as n from kept group by base
  ), keyed as (
    select k.*, case when p.n > 1 and k.place <> '' then k.base || ' · ' || k.place
                     else k.base end as key0
    from kept k join places p using (base)
  )
  select keyed.*,
    case when row_number() over (partition by key0 order by pos) = 1 then key0
         else key0 || ' #' || row_number() over (partition by key0 order by pos) end as app_key
  from keyed;

  v_total := (select count(*) from _in);
  if v_total = 0 then
    -- An empty read never wipes the applications (Airtable hiccup, wrong
    -- view): it's refused instead.
    raise exception 'airtable_empty' using errcode = 'P0001';
  end if;

  -- Same-name students used to be told apart by their order; a stored
  -- application under an old key that matches an incoming one on name,
  -- institution and country takes the new key, with its history.
  for m in
    select distinct on (a.app_key) i.app_key as new_key, a.app_key as old_key
    from _in i
    join public.applications a
      on lower(a.student) = lower(i.student) and lower(a.rto) = lower(i.rto)
     and lower(a.country) = lower(i.country)
    where not exists (select 1 from public.applications x where x.app_key = i.app_key)
      and not exists (select 1 from _in y where y.app_key = a.app_key)
    order by a.app_key, i.pos
  loop
    if exists (select 1 from public.applications where app_key = m.new_key) then
      continue;                         -- taken by an earlier match
    end if;
    update public.applications set app_key = m.new_key where app_key = m.old_key;
    update public.application_changes set app_key = m.new_key where app_key = m.old_key;
  end loop;

  -- What differs.
  create temp table _diff on commit drop as
  select i.app_key, i.student, f.field, coalesce(f.old, '') as old_value,
         coalesce(f.new, '') as new_value
  from _in i
  join public.applications a on a.app_key = i.app_key
  cross join lateral (values
    ('rto', a.rto, i.rto), ('country', a.country, i.country),
    ('doc_date', a.doc_date, i.doc_date), ('app_date', a.app_date, i.app_date),
    ('offer_date', a.offer_date, i.offer_date), ('coe_date', a.coe_date, i.coe_date),
    ('status', a.status, i.status), ('assignee', a.assignee, i.assignee),
    ('todo', a.todo, i.todo), ('follow_up', a.follow_up, i.follow_up)
  ) as f(field, old, new)
  where coalesce(f.old, '') <> coalesce(f.new, '');

  create temp table _new on commit drop as
  select i.app_key from _in i
  where not exists (select 1 from public.applications a where a.app_key = i.app_key);
  create temp table _gone on commit drop as
  select a.app_key, a.student, a.status from public.applications a
  where not exists (select 1 from _in i where i.app_key = a.app_key);
  v_added := (select count(*) from _new);
  v_removed := (select count(*) from _gone);
  v_changed := (select count(distinct app_key) from _diff);

  -- Each statement only when it has something to do (every write tells the
  -- devices to download again).
  if exists (
       select 1 from _in i join public.applications a on a.app_key = i.app_key
       where a.position <> i.pos or a.student <> i.student
          or exists (select 1 from _diff d where d.app_key = i.app_key)) then
    update public.applications a set
      student = i.student, rto = i.rto, country = i.country,
      doc_date = i.doc_date, app_date = i.app_date, offer_date = i.offer_date,
      coe_date = i.coe_date, status = i.status, assignee = i.assignee,
      todo = i.todo, follow_up = i.follow_up, position = i.pos,
      updated_at = case when exists (select 1 from _diff d where d.app_key = i.app_key)
                        then v_now else a.updated_at end
    from _in i
    where a.app_key = i.app_key
      and (a.position <> i.pos or a.student <> i.student
           or exists (select 1 from _diff d where d.app_key = i.app_key));
  end if;

  if v_added > 0 then
    v_base := private.applications_next_id();
    insert into public.applications (id, app_key, student, rto, country,
      doc_date, app_date, offer_date, coe_date, status, assignee, todo,
      follow_up, position, updated_at)
    select v_base + row_number() over (order by i.pos), i.app_key, i.student,
      i.rto, i.country, i.doc_date, i.app_date, i.offer_date, i.coe_date,
      i.status, i.assignee, i.todo, i.follow_up, i.pos, v_now
    from _in i join _new n using (app_key);
  end if;

  if v_removed > 0 then
    delete from public.applications a using _gone g where a.app_key = g.app_key;
  end if;

  if v_first or v_added + v_changed + v_removed > 0 then
    v_import := private.applications_next_id();
    insert into public.application_imports (id, imported_at, file_name, total,
      added, changed, removed, device)
    values (v_import, v_now, p_label, v_total, v_added, v_changed, v_removed,
            'Airtable sync');
    if not v_first then
      v_base := private.applications_next_id();
      -- In the CSV upload's order: each application in turn (added, or its
      -- changed fields), then the removed ones.
      insert into public.application_changes (id, import_id, app_key, student,
        field, old_value, new_value, changed_at)
      select v_base + row_number() over (order by grp, pos, ord), v_import,
        app_key, student, field, old_value, new_value, v_now
      from (
        select 1 as grp, i.pos, 0 as ord, i.app_key, i.student,
               'added' as field, '' as old_value, i.status as new_value
        from _in i join _new n using (app_key)
        union all
        select 1, i.pos, array_position(fields, d.field), d.app_key,
               d.student, d.field, d.old_value, d.new_value
        from _diff d join _in i using (app_key)
        union all
        select 2, 0, 0, g.app_key, g.student, 'removed', g.status, ''
        from _gone g
      ) ch;
    end if;
  end if;

  return jsonb_build_object('total', v_total, 'added', v_added,
    'changed', v_changed, 'removed', v_removed, 'first', v_first);
end $$;
-- Monthly budget (Airtable free plan: 1,000 calls per workspace). Above
-- these, the schedule slows down and then stops until the 1st; "Sync now"
-- keeps a small reserve.
create or replace function private.airtable_budget()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"limit": 1000, "slow": 700, "stop_changes": 850,
           "stop_nightly": 920, "stop_manual": 980}'::jsonb;
$$;

-- One sync: reads Airtable (p_kind 'changes', 'full'), applies it, notes the
-- result. Only one at a time. Returns the result, or {skipped: reason}.
-- Errors are noted and returned ({error: code}), never raised, so the
-- schedule keeps going.
create or replace function private.airtable_run(p_kind text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_fetch jsonb;
  v_apply jsonb;
  v_result jsonb;
  v_code text;
  v_detail text;
begin
  if not coalesce((select enabled from private.airtable_config where id = 1), false) then
    return jsonb_build_object('skipped', 'disabled');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('airtable_sync')) then
    return jsonb_build_object('skipped', 'busy');
  end if;
  update private.airtable_state set last_run_at = now(), last_kind = p_kind where id = 1;
  begin
    v_fetch := private.airtable_fetch(p_kind = 'full');
    v_apply := private.applications_apply(p_label);
    v_result := v_apply || v_fetch;
    update private.airtable_state
      set last_ok_at = now(), last_result = v_result, last_error = null
      where id = 1;
    return v_result;
  exception when others then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    -- The error undid the call count too: count at least the call that
    -- failed (the pages read before it can't be known here).
    if v_code like 'airtable\_%' then
      insert into private.airtable_usage as u (month, calls)
        values (date_trunc('month', now() at time zone 'Africa/Nairobi')::date, 1)
        on conflict (month) do update set calls = u.calls + 1;
    end if;
    update private.airtable_state
      set last_error = v_code || case when coalesce(v_detail, '') <> ''
                                      then ': ' || v_detail else '' end,
          last_error_at = now()
      where id = 1;
    return jsonb_build_object('error', v_code);
  end;
end $$;

-- What the schedule calls. 'changes' every 30 minutes in working hours,
-- 'full' at night; each checks the budget first.
create or replace function private.airtable_scheduled(p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b jsonb := private.airtable_budget();
  used int := private.airtable_calls_this_month();
  s private.airtable_state;
begin
  select * into s from private.airtable_state where id = 1;
  if p_kind = 'full' then
    if used >= (b->>'stop_nightly')::int then
      return jsonb_build_object('skipped', 'budget');
    end if;
    return private.airtable_run('full', 'Airtable (nightly)');
  end if;
  if used >= (b->>'stop_changes')::int then
    return jsonb_build_object('skipped', 'budget');
  end if;
  -- Over the "slow" mark: once an hour instead of every 30 minutes.
  if used >= (b->>'slow')::int and s.last_run_at > now() - interval '50 minutes' then
    return jsonb_build_object('skipped', 'slow');
  end if;
  return private.airtable_run('changes', 'Airtable');
end $$;

-- For the app: how the Airtable sync is doing (any signed-in person).
create or replace function public.airtable_status(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s private.airtable_state;
  b jsonb := private.airtable_budget();
begin
  perform private.token_role(p_token);
  select * into s from private.airtable_state where id = 1;
  return jsonb_build_object(
    'enabled', coalesce((select enabled from private.airtable_config where id = 1), false),
    'last_ok_at', s.last_ok_at,
    'last_full_at', s.last_full_at,
    'last_run_at', s.last_run_at,
    'last_result', s.last_result,
    'last_error', s.last_error,
    'last_error_at', s.last_error_at,
    'calls_this_month', private.airtable_calls_this_month(),
    'limit', (b->>'limit')::int,
    'slow_at', (b->>'slow')::int,
    'stop_at', (b->>'stop_changes')::int,
    'manual_stop_at', (b->>'stop_manual')::int);
end $$;

-- "Sync now" (admin and admin team): reads what changed since the last
-- read; p_full (admin only) reads everything, which also catches records
-- deleted in Airtable.
create or replace function public.airtable_sync_now(p_token text, p_full boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  b jsonb := private.airtable_budget();
begin
  if r not in ('admin', 'admin_team') or (p_full and r <> 'admin') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if private.airtable_calls_this_month() >= (b->>'stop_manual')::int then
    raise exception 'airtable_budget' using errcode = 'P0001';
  end if;
  return private.airtable_run(case when p_full then 'full' else 'changes' end,
                              'Airtable (Sync now)');
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.airtable_status(text) from public;
revoke all on function public.airtable_sync_now(text, boolean) from public;
grant execute on function public.airtable_status(text) to anon, authenticated;
grant execute on function public.airtable_sync_now(text, boolean) to anon, authenticated;

-- The schedule (UTC; Kenya is UTC+3). Changes: every 30 minutes from 08:00
-- to 18:30 Kenya time, Monday to Saturday. Everything: 02:00 Kenya time.
do $$
begin
  perform cron.unschedule(jobname) from cron.job
    where jobname in ('airtable-changes', 'airtable-nightly');
  perform cron.schedule('airtable-changes', '*/30 5-15 * * 1-6',
    $job$select private.airtable_scheduled('changes')$job$);
  perform cron.schedule('airtable-nightly', '0 23 * * *',
    $job$select private.airtable_scheduled('full')$job$);
end $$;

-- Saturdays: Airtable is read once an hour (08:00 to 18:00 Kenya time)
-- instead of every 30 minutes, to save API calls. Monday to Friday stays
-- every 30 minutes; the nightly full read is unchanged.
do $$
begin
  perform cron.unschedule(jobname) from cron.job
    where jobname in ('airtable-changes', 'airtable-saturday');
  perform cron.schedule('airtable-changes', '*/30 5-15 * * 1-5',
    $job$select private.airtable_scheduled('changes')$job$);
  perform cron.schedule('airtable-saturday', '0 5-15 * * 6',
    $job$select private.airtable_scheduled('changes')$job$);
end $$;

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
  if private.token_role(p_token) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from private.error_reports where id is not null;
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

-- ===== migrations/20261104140000_secure_reads_step2.sql =====
-- ===== Secure reads, step 2 (apply once every device has the new app) =====
-- The publishable key alone can no longer read any data: no open table
-- reads, no data in live updates, and the old open snapshot refuses (older
-- apps then show "offline" instead of seeing an empty database).
do $$
declare t text;
begin
  foreach t in array array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes']
  loop
    execute format('drop policy if exists "Anyone can read" on public.%I', t);
    execute format('revoke select on public.%I from anon, authenticated', t);
    begin
      execute format('alter publication supabase_realtime drop table public.%I', t);
    exception when undefined_object then null; end;
  end loop;
end $$;

create or replace function public.sync_snapshot()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'update_required' using errcode = '42501';
end $$;

-- ===== migrations/20261109190000_user_accounts_step2.sql =====
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

-- ===== migrations/20261112150000_security_pages_backup.sql =====
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

-- ===== migrations/20261112160000_search_ignores_punctuation.sql =====
-- ===== Daily report search ignores punctuation (2026-11-12) =====
-- "o'brien", "O. Brien" and "obrien" find the same report; commas, full
-- stops and dashes in a search no longer stop it matching. Every word of
-- the search must appear (in any order) in the description, reference,
-- next action or blocker.

create or replace function private.search_key(p_text text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '', 'g');
$$;

create or replace function private.search_hit(p_search text, p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select not exists (
    select 1
    from regexp_split_to_table(
           lower(regexp_replace(coalesce(p_search, ''), '[''’`]', '', 'g')),
           '[^a-z0-9]+') w
    where w <> '' and position(w in private.search_key(p_text)) = 0);
$$;

do $$
declare src text;
begin
  src := pg_get_functiondef('public.report_list(text, jsonb)'::regprocedure);
  if position('search_hit' in src) = 0 then
    src := regexp_replace(src,
      'and \(v_search is null.*?r\.blocker ilike ''%'' \|\| v_search \|\| ''%''\)',
      'and (v_search is null or private.search_hit(v_search, concat_ws('' '', '
        || 'r.description, r.reference, r.next_action, r.blocker)))');
    if position('search_hit' in src) = 0 then
      raise exception 'report_list search clause not found';
    end if;
    execute src;
  end if;
end $$;

revoke all on function private.search_key(text), private.search_hit(text, text)
  from public, anon, authenticated;

-- ===== migrations/20261112170000_report_start.sql =====
-- Daily reports open in one round trip: who you are, the departments and
-- people you see, and your own day (today's reports, everything still open
-- and this week so far), instead of a call for the page and then three
-- more for the lists.
create or replace function public.report_start(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_today date := private.today();
  v_monday date := v_today - (extract(isodow from v_today)::int - 1);
begin
  return jsonb_build_object(
    'meta', public.reports_meta(p_token),
    'day', public.report_list(p_token, jsonb_build_object(
      'from', v_today, 'to', v_today, 'user_id', me)),
    'open', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'open_only', true)),
    'week', public.report_list(p_token, jsonb_build_object(
      'from', v_monday, 'to', v_today, 'user_id', me))
  );
end $$;

revoke all on function public.report_start(text) from public;
grant execute on function public.report_start(text) to anon, authenticated;

-- ===== migrations/20261115090000_daily_tasks.sql =====
-- Daily reports become tasks.
--
-- Every entry is now a task that belongs to one person. It can be on their
-- to-do list (to_do / in_progress / blocked) or done. When done it is
-- submitted for the day it was submitted on (report_date is set by the server,
-- never picked by the user), and a reviewer approves it or returns it with a
-- comment. Directors, managers and department heads can assign tasks to anyone,
-- with an urgency colour. People are notified about the things that need them.
--
-- The old rows are dropped on purpose: the business agreed the old daily
-- report data does not need to be kept.

truncate public.report_comments, public.activity_changes, public.activity_reports
  restart identity;

drop index if exists public.activity_reports_open_idx;

alter table public.activity_reports
  drop constraint if exists activity_reports_status_check,
  drop constraint if exists activity_reports_priority_check,
  drop constraint if exists activity_reports_next_action_check,
  drop column if exists next_action,
  drop column if exists priority;

alter table public.activity_reports
  alter column report_date drop not null,
  alter column report_date drop default,
  alter column status set default 'to_do',
  add column if not exists details text not null default ''
    check (length(details) <= 4000),
  add column if not exists urgency text not null default 'normal'
    check (urgency in ('low', 'normal', 'high', 'urgent')),
  add column if not exists review text not null default 'none'
    check (review in ('none', 'submitted', 'approved', 'returned')),
  add column if not exists submitted_at timestamptz,
  add column if not exists reviewed_by bigint
    references private.app_users(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add constraint activity_reports_status_check
    check (status in ('to_do', 'in_progress', 'blocked', 'done'));

create index if not exists activity_reports_open_idx
  on public.activity_reports (user_id) where status <> 'done';
create index if not exists activity_reports_review_idx
  on public.activity_reports (review) where review = 'submitted';
create index if not exists activity_reports_assigned_idx
  on public.activity_reports (assigned_by) where assigned_by is not null;

alter table public.activity_changes
  drop constraint if exists activity_changes_action_check,
  add constraint activity_changes_action_check
    check (action in ('created', 'edited', 'deleted', 'submitted',
                      'approved', 'returned'));

-- Comments double as the review timeline.
alter table public.report_comments
  drop constraint if exists report_comments_body_check,
  add column if not exists kind text not null default 'comment'
    check (kind in ('comment', 'submitted', 'approved', 'returned'));
alter table public.report_comments
  add constraint report_comments_body_check
    check (length(body) <= 1000 and (kind <> 'comment' or length(trim(body)) > 0));

-- Notifications ----------------------------------------------------------
create table if not exists public.report_notifications (
  id bigint generated always as identity primary key,
  user_id bigint not null references private.app_users(id) on delete cascade,
  kind text not null check (kind in ('assigned', 'submitted', 'approved',
    'returned', 'comment', 'blocked', 'due_today', 'overdue', 'reminder',
    'reassigned')),
  report_id bigint references public.activity_reports(id) on delete cascade,
  actor_id bigint references private.app_users(id) on delete set null,
  body text not null default '',
  dedupe text unique,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists report_notifications_user_idx
  on public.report_notifications (user_id, id desc);
alter table public.report_notifications enable row level security;
revoke all on public.report_notifications from anon, authenticated;

create or replace function private.notify(p_user bigint, p_kind text,
    p_report bigint, p_actor bigint, p_body text default '',
    p_dedupe text default null)
returns void
language sql
security definer
set search_path to ''
as $$
  insert into public.report_notifications (user_id, kind, report_id, actor_id, body, dedupe)
  select p_user, p_kind, p_report, p_actor, left(coalesce(p_body, ''), 300), p_dedupe
  where p_user is not null and p_user is distinct from p_actor
    and exists (select 1 from private.app_users where id = p_user and active)
  on conflict (dedupe) do nothing;
$$;

-- Access -----------------------------------------------------------------
-- Who can see a task: the owner, whoever assigned it, and the people whose
-- report scope covers the owner.
create or replace function private.can_see_task(p_user bigint, r public.activity_reports)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(r.user_id = p_user or r.assigned_by is not distinct from p_user
      or private.can_see_report(p_user, r.user_id, r.department_id), false);
$$;

-- Who can review: never the owner. The person who assigned it, anyone with
-- company-wide scope, or the head of the task's department.
create or replace function private.can_review(p_user bigint, r public.activity_reports)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(r.user_id <> p_user and (
    r.assigned_by is not distinct from p_user
    or private.report_scope(p_user) = 'all'
    or (private.report_scope(p_user) = 'department'
        and r.department_id is not distinct from
            (select department_id from private.app_users where id = p_user))), false);
$$;

create or replace function private.can_assign(p_user bigint)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(private.report_scope(p_user) <> 'own', false);
$$;

create or replace function private.report_json(r public.activity_reports)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select to_jsonb(r) || jsonb_build_object(
    'user_name', (select full_name from private.app_users where id = r.user_id),
    'department_name', (select name from public.departments where id = r.department_id),
    'assigned_by_name', (select full_name from private.app_users where id = r.assigned_by),
    'reviewed_by_name', (select full_name from private.app_users where id = r.reviewed_by),
    'comment_count', (select count(*) from public.report_comments c
                      where c.report_id = r.id and c.kind = 'comment'),
    'last_review_note', (select c.body from public.report_comments c
                         where c.report_id = r.id and c.kind in ('approved', 'returned')
                         order by c.id desc limit 1));
$$;

-- Meta -------------------------------------------------------------------
create or replace function public.reports_meta(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
begin
  return jsonb_build_object(
    'today', private.today(),
    'now', private.kenya_now_text(),
    'me', private.user_json(me) || jsonb_build_object(
      'scope', scope, 'can_assign', private.can_assign(me)),
    'departments', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.position, d.name)
      from public.departments d), '[]'::jsonb),
    -- People a manager can filter by, and assign to. Anyone who can assign
    -- can assign to anyone active.
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'full_name', u.full_name,
               'department_id', u.department_id, 'active', u.active)
             order by lower(u.full_name))
      from private.app_users u
      where scope <> 'own' or u.id = me), '[]'::jsonb)
  );
end $$;

-- List -------------------------------------------------------------------
create or replace function public.report_list(p_token text, p_filter jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_from date := nullif(f->>'from', '')::date;
  v_to date := nullif(f->>'to', '')::date;
  v_dept bigint := nullif(f->>'department_id', '')::bigint;
  v_user bigint := nullif(f->>'user_id', '')::bigint;
  v_statuses text[] := case when jsonb_typeof(f->'statuses') = 'array'
    then array(select jsonb_array_elements_text(f->'statuses')) end;
  v_reviews text[] := case when jsonb_typeof(f->'reviews') = 'array'
    then array(select jsonb_array_elements_text(f->'reviews')) end;
  v_urgency text := nullif(f->>'urgency', '');
  v_open boolean := coalesce((f->>'open_only')::boolean, false);
  v_overdue boolean := coalesce((f->>'overdue_only')::boolean, false);
  v_assigned_by_me boolean := coalesce((f->>'assigned_by_me')::boolean, false);
  v_to_review boolean := coalesce((f->>'to_review')::boolean, false);
  v_reviewed_by_me boolean := coalesce((f->>'reviewed_by_me')::boolean, false);
  v_search text := nullif(trim(coalesce(f->>'search', '')), '');
  v_id bigint := case when v_search ~ '^#?[0-9]{1,12}$'
    then ltrim(v_search, '#')::bigint end;
  v_limit int := least(greatest(coalesce((f->>'limit')::int, 500), 1), 3000);
begin
  return coalesce((
    select jsonb_agg(private.report_json(r) order by
        coalesce(r.submitted_at, r.updated_at) desc, r.id desc)
    from (
      select * from public.activity_reports r
      where private.can_see_task(me, r)
        and (v_from is null or r.report_date >= v_from)
        and (v_to is null or r.report_date <= v_to)
        and (v_dept is null or r.department_id = v_dept)
        and (v_user is null or r.user_id = v_user)
        and (v_statuses is null or r.status = any(v_statuses))
        and (v_reviews is null or r.review = any(v_reviews))
        and (v_urgency is null or r.urgency = v_urgency)
        and (not v_open or r.status <> 'done' or r.review = 'returned')
        and (not v_overdue or (r.status <> 'done' and r.due_date < private.today()))
        and (not v_assigned_by_me or r.assigned_by is not distinct from me)
        and (not v_to_review or (r.review = 'submitted' and private.can_review(me, r)))
        and (not v_reviewed_by_me or r.reviewed_by is not distinct from me)
        and (v_search is null or r.id = v_id or private.search_hit(v_search,
              concat_ws(' ', r.description, r.details, r.reference, r.blocker,
                (select full_name from private.app_users where id = r.user_id),
                (select full_name from private.app_users where id = r.assigned_by),
                (select name from public.departments where id = r.department_id))))
      order by coalesce(r.submitted_at, r.updated_at) desc, r.id desc
      limit v_limit
    ) r), '[]'::jsonb);
end $$;

-- Save -------------------------------------------------------------------
-- p_report: id?, user_id? (assign to), description (title), details,
-- reference, outputs, status, urgency, due_date, blocker, submit (bool).
create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  owner private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  v_for bigint := nullif(p_report->>'user_id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_status text := coalesce(nullif(p_report->>'status', ''), 'to_do');
  v_urgency text := coalesce(nullif(p_report->>'urgency', ''), 'normal');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_submit boolean := coalesce((p_report->>'submit')::boolean, false);
  v_title text := trim(coalesce(p_report->>'description', ''));
  v_dept bigint;
  v_assigned bigint;
  v_owner bigint;
  v_review text;
  v_report_date date;
  v_submitted timestamptz;
begin
  select * into u from private.app_users where id = me;
  if v_status not in ('to_do', 'in_progress', 'blocked', 'done') then
    raise exception 'bad_status' using errcode = '22023';
  end if;
  if v_urgency not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'bad_urgency' using errcode = '22023';
  end if;
  if length(v_title) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  if v_submit then v_status := 'done'; end if;

  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if not (before.user_id = me or before.assigned_by is not distinct from me or u.role = 'admin') then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    -- The owner can't change work once it is waiting for review or approved.
    if before.review in ('submitted', 'approved') and before.user_id = me
       and before.assigned_by is distinct from me and u.role is distinct from 'admin' then
      raise exception 'already_submitted' using errcode = '42501';
    end if;
    v_owner := before.user_id;
    v_assigned := before.assigned_by;
    -- Whoever assigned the task can hand it to someone else.
    if v_for is not null and v_for <> before.user_id
       and (before.assigned_by is not distinct from me or u.role = 'admin') then
      select * into owner from private.app_users where id = v_for and active;
      if owner.id is null then
        raise exception 'unknown_user' using errcode = '22023';
      end if;
      v_owner := owner.id;
    end if;
    v_dept := case when v_owner = before.user_id then before.department_id
                   else owner.department_id end;
  elsif v_for is not null and v_for <> me then
    if not private.can_assign(me) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    select * into owner from private.app_users where id = v_for and active;
    if owner.id is null then
      raise exception 'unknown_user' using errcode = '22023';
    end if;
    v_owner := owner.id;
    v_dept := owner.department_id;
    v_assigned := me;
    v_submit := false;
    if v_status = 'done' then v_status := 'to_do'; end if;
  else
    v_owner := me;
    v_dept := u.department_id;
  end if;

  if v_status = 'blocked' and length(trim(coalesce(p_report->>'blocker', ''))) = 0 then
    raise exception 'blocker_required' using errcode = '22023';
  end if;

  v_review := coalesce(before.review, 'none');
  v_report_date := before.report_date;
  v_submitted := before.submitted_at;
  if v_submit then
    if v_owner <> me then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_review := 'submitted';
    v_report_date := private.today();
    v_submitted := now();
  elsif v_status <> 'done' and v_review = 'approved' then
    v_review := 'none';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date,
        description, details, reference, outputs, status, blocker, urgency,
        due_date, assigned_by, review, submitted_at)
      values (v_owner, v_dept, v_report_date, left(v_title, 2000),
        left(trim(coalesce(p_report->>'details', '')), 4000),
        left(trim(coalesce(p_report->>'reference', '')), 200),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, left(trim(coalesce(p_report->>'blocker', '')), 1000), v_urgency,
        v_due, v_assigned, v_review, v_submitted)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
    if v_assigned is not null then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
    end if;
  else
    update public.activity_reports set
        user_id = v_owner,
        department_id = v_dept,
        report_date = v_report_date,
        description = left(v_title, 2000),
        details = left(trim(coalesce(p_report->>'details', '')), 4000),
        reference = left(trim(coalesce(p_report->>'reference', '')), 200),
        outputs = private.clean_outputs(p_report->'outputs', v_dept, before.outputs),
        status = v_status,
        blocker = case when v_status = 'blocked'
                       then left(trim(coalesce(p_report->>'blocker', '')), 1000) else '' end,
        urgency = v_urgency,
        due_date = v_due,
        review = v_review,
        submitted_at = v_submitted,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, case when v_submit then 'submitted' else 'edited' end,
              to_jsonb(before), to_jsonb(saved));
    if saved.user_id <> before.user_id then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
      perform private.notify(before.user_id, 'reassigned', saved.id, me, saved.description);
    elsif before.assigned_by is not distinct from me and saved.user_id <> me
          and (saved.urgency <> before.urgency or saved.due_date is distinct from before.due_date
               or saved.description <> before.description) then
      perform private.notify(saved.user_id, 'assigned', saved.id, me,
        'Updated: ' || saved.description);
    end if;
    if saved.status = 'blocked' and before.status <> 'blocked' then
      perform private.notify(saved.assigned_by, 'blocked', saved.id, me, saved.blocker);
    end if;
  end if;

  if v_submit then
    insert into public.report_comments (report_id, user_id, kind, body)
      values (saved.id, me, 'submitted', left(trim(coalesce(p_report->>'note', '')), 1000));
    perform private.notify(saved.assigned_by, 'submitted', saved.id, me, saved.description);
  end if;
  return private.report_json(saved);
end $$;

-- Review -----------------------------------------------------------------
create or replace function public.report_review(p_token text, p_report bigint,
    p_decision text, p_comment text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  saved public.activity_reports;
  v_note text := left(trim(coalesce(p_comment, '')), 1000);
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_review(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'returned') then
    raise exception 'bad_decision' using errcode = '22023';
  end if;
  if r.review <> 'submitted' and not (r.review in ('approved', 'returned')
                                      and r.reviewed_by is not distinct from me) then
    raise exception 'not_submitted' using errcode = '22023';
  end if;
  if p_decision = 'returned' and length(v_note) = 0 then
    raise exception 'comment_required' using errcode = '22023';
  end if;
  update public.activity_reports set
      review = p_decision,
      status = case when p_decision = 'returned' then 'in_progress' else 'done' end,
      reviewed_by = me, reviewed_at = now(), updated_at = now()
    where id = p_report
    returning * into saved;
  insert into public.report_comments (report_id, user_id, kind, body)
    values (p_report, me, p_decision, v_note);
  insert into public.activity_changes (report_id, changed_by, action, before, after)
    values (p_report, me, p_decision, to_jsonb(r), to_jsonb(saved));
  perform private.notify(saved.user_id, p_decision, saved.id, me,
    case when v_note = '' then saved.description else v_note end);
  return private.report_json(saved);
end $$;

-- Delete -----------------------------------------------------------------
create or replace function public.report_delete(p_token text, p_report bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  v_role text := (select role from private.app_users where id = me);
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then return; end if;
  if not (r.assigned_by is not distinct from me or v_role = 'admin'
          or (r.user_id = me and r.assigned_by is null and r.review <> 'approved')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.activity_reports where id = p_report;
  insert into public.activity_changes (report_id, changed_by, action, before)
    values (p_report, me, 'deleted', to_jsonb(r));
end $$;

-- Comments / timeline ----------------------------------------------------
create or replace function public.report_comments(p_token text, p_report bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null or not private.can_see_task(me, r) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'body', c.body, 'kind', c.kind, 'created_at', c.created_at,
      'user_id', c.user_id,
      'user_name', (select full_name from private.app_users where id = c.user_id))
      order by c.id)
    from public.report_comments c where c.report_id = p_report), '[]'::jsonb);
end $$;

create or replace function public.report_comment_add(p_token text, p_report bigint, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  v_body text := left(trim(coalesce(p_body, '')), 1000);
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_see_task(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if length(v_body) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  insert into public.report_comments (report_id, user_id, body) values (p_report, me, v_body);
  perform private.notify(r.user_id, 'comment', r.id, me, v_body);
  if r.assigned_by is distinct from r.user_id then
    perform private.notify(r.assigned_by, 'comment', r.id, me, v_body);
  end if;
  if r.reviewed_by is distinct from r.user_id and r.reviewed_by is distinct from r.assigned_by then
    perform private.notify(r.reviewed_by, 'comment', r.id, me, v_body);
  end if;
  return public.report_comments(p_token, p_report);
end $$;

create or replace function public.report_comment_delete(p_token text, p_comment bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  delete from public.report_comments c
  where c.id = p_comment and c.kind = 'comment'
    and (c.user_id = me or (select role from private.app_users where id = me) = 'admin');
end $$;

create or replace function public.report_history(p_token text, p_report bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null then
    select (jsonb_populate_record(null::public.activity_reports, c.before)).* into r
      from public.activity_changes c
      where c.report_id = p_report and c.action = 'deleted'
      order by c.id desc limit 1;
  end if;
  if r.id is null or not private.can_see_task(me, r) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', c.action, 'changed_at', c.changed_at,
      'changed_by', (select full_name from private.app_users where id = c.changed_by),
      'before', c.before, 'after', c.after) order by c.id)
    from public.activity_changes c where c.report_id = p_report), '[]'::jsonb);
end $$;

-- Notifications ----------------------------------------------------------
-- Makes the once-a-day reminders, then returns the counts the app shows as
-- badges. Cheap enough to poll every minute.
create or replace function private.make_reminders(p_user bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := private.today();
  v_now timestamp := now() at time zone 'Africa/Nairobi';
  r record;
begin
  for r in select id, description, due_date from public.activity_reports
           where user_id = p_user and status <> 'done' and due_date <= v_today
  loop
    if r.due_date = v_today then
      perform private.notify(p_user, 'due_today', r.id, null, r.description,
        'due:' || r.id || ':' || v_today);
    else
      perform private.notify(p_user, 'overdue', r.id, null, r.description,
        'over:' || r.id || ':' || p_user);
    end if;
  end loop;
  -- Assigners hear once when something they handed out goes overdue.
  for r in select id, description, assigned_by from public.activity_reports
           where assigned_by = p_user and user_id <> p_user and status <> 'done'
             and due_date < v_today
  loop
    perform private.notify(p_user, 'overdue', r.id, null, r.description,
      'late:' || r.id || ':' || p_user);
  end loop;
  -- A nudge late on a working day when nothing was submitted.
  if extract(isodow from v_today) < 6 and extract(hour from v_now) >= 16
     and (select department_id from private.app_users where id = p_user) is not null
     and not exists (select 1 from public.activity_reports
                     where user_id = p_user and report_date = v_today) then
    perform private.notify(p_user, 'reminder', null, null,
      'You haven''t submitted anything for today yet.',
      'remind:' || p_user || ':' || v_today);
  end if;
end $$;

create or replace function public.report_badge(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  perform private.make_reminders(me);
  return jsonb_build_object(
    'unread', (select count(*) from public.report_notifications
               where user_id = me and read_at is null),
    'to_review', (select count(*) from public.activity_reports r
                  where r.review = 'submitted' and private.can_review(me, r)),
    'submitted_today', exists (select 1 from public.activity_reports
                               where user_id = me and report_date = private.today()),
    'needs_report', (select department_id from private.app_users where id = me) is not null);
end $$;

create or replace function public.report_notifications(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'report_id', n.report_id, 'body', n.body,
      'created_at', n.created_at, 'read', n.read_at is not null,
      'actor_name', (select full_name from private.app_users where id = n.actor_id),
      'task', (select description from public.activity_reports where id = n.report_id),
      'urgency', (select urgency from public.activity_reports where id = n.report_id))
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n), '[]'::jsonb);
end $$;

create or replace function public.report_notifications_read(p_token text, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  update public.report_notifications set read_at = now()
    where user_id = me and read_at is null
      and (p_ids is null or id = any(p_ids));
  delete from public.report_notifications
    where user_id = me and created_at < now() - interval '60 days';
end $$;

-- Start ------------------------------------------------------------------
-- Everything the page needs on open, in one round trip.
create or replace function public.report_start(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return jsonb_build_object(
    'meta', public.reports_meta(p_token),
    'badge', public.report_badge(p_token),
    'tasks', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'open_only', true)),
    'submissions', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'reviews', jsonb_build_array('submitted', 'approved'),
      'from', private.today() - 60, 'limit', 300))
  );
end $$;

-- Summary ----------------------------------------------------------------
create or replace function public.report_summary(p_token text, p_from date, p_to date,
    p_department bigint, p_user bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
  today date := private.today();
begin
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', today,
    'working_days', (
      select count(*) from generate_series(p_from, least(p_to, today), interval '1 day') d
      where extract(isodow from d) < 6),
    -- Work status right now, for every task in view (not only the period).
    'status', coalesce((
      select jsonb_object_agg(status, n) from (
        select r.status, count(*) n from public.activity_reports r
        where private.can_see_task(me, r)
          and (r.status <> 'done' or r.report_date between p_from and p_to)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        group by r.status) s), '{}'::jsonb),
    'review', coalesce((
      select jsonb_object_agg(review, n) from (
        select r.review, count(*) n from public.activity_reports r
        where private.can_see_task(me, r)
          and r.report_date between p_from and p_to
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        group by r.review) s), '{}'::jsonb),
    'departments', coalesce((
      select jsonb_agg(x order by x->>'position', x->>'name') from (
        select jsonb_build_object(
          'id', d.id, 'name', d.name, 'position', lpad(d.position::text, 6, '0'),
          'activities', count(r.id) filter (where r.report_date between p_from and p_to),
          'completed', count(r.id) filter (where r.report_date between p_from and p_to
                                           and r.review = 'approved'),
          'open', count(r.id) filter (where r.status <> 'done'),
          'blocked', count(r.id) filter (where r.status = 'blocked'),
          'awaiting', count(r.id) filter (where r.review = 'submitted'),
          'people', count(distinct r.user_id) filter (where r.report_date between p_from and p_to),
          'outputs', coalesce((
            select jsonb_object_agg(k, total) from (
              select o.key k, sum((o.value #>> '{}')::int) total
              from public.activity_reports r2, jsonb_each(r2.outputs) o
              where r2.department_id = d.id
                and private.can_see_task(me, r2)
                and r2.report_date between p_from and p_to
                and (p_user is null or r2.user_id = p_user)
              group by o.key) t), '{}'::jsonb)) x
        from public.departments d
        left join public.activity_reports r
          on r.department_id = d.id
         and (r.status <> 'done' or r.report_date between p_from and p_to)
         and private.can_see_task(me, r)
         and (p_user is null or r.user_id = p_user)
        where (p_department is null or d.id = p_department)
          and (scope = 'all' or d.id = my_dept)
          and (p_user is null
               or d.id = (select department_id from private.app_users where id = p_user)
               or r.id is not null)
          and (d.active or r.id is not null)
        group by d.id) s), '[]'::jsonb),
    'compliance', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id, 'full_name', u.full_name,
        'department_id', u.department_id,
        'department_name', (select name from public.departments where id = u.department_id),
        'days_submitted', (select count(distinct r.report_date) from public.activity_reports r
                           where r.user_id = u.id and r.report_date between p_from and p_to),
        'entries', (select count(*) from public.activity_reports r
                    where r.user_id = u.id and r.report_date between p_from and p_to),
        'open', (select count(*) from public.activity_reports r
                 where r.user_id = u.id and r.status <> 'done'),
        'last_date', (select max(r.report_date) from public.activity_reports r where r.user_id = u.id),
        'submitted_today', exists (select 1 from public.activity_reports r
                                   where r.user_id = u.id and r.report_date = today))
        order by lower(u.full_name))
      from private.app_users u
      where u.active and u.department_id is not null
        and (p_department is null or u.department_id = p_department)
        and (p_user is null or u.id = p_user)
        and (scope = 'all'
             or (scope = 'department' and u.department_id = my_dept)
             or u.id = me)), '[]'::jsonb),
    'overdue', coalesce((
      select jsonb_agg(private.report_json(r) order by r.due_date, r.id) from (
        select * from public.activity_reports r
        where r.status <> 'done' and r.due_date < today
          and private.can_see_task(me, r)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.due_date limit 200) r), '[]'::jsonb),
    'attention', coalesce((
      select jsonb_agg(private.report_json(r) order by r.updated_at desc, r.id desc) from (
        select * from public.activity_reports r
        where (r.status = 'blocked' or r.review = 'returned'
               or (r.urgency = 'urgent' and r.status <> 'done'))
          and private.can_see_task(me, r)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.updated_at desc limit 200) r), '[]'::jsonb)
  );
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function
  public.reports_meta(text), public.report_list(text, jsonb),
  public.report_save(text, jsonb), public.report_review(text, bigint, text, text),
  public.report_delete(text, bigint), public.report_comments(text, bigint),
  public.report_comment_add(text, bigint, text), public.report_comment_delete(text, bigint),
  public.report_history(text, bigint), public.report_badge(text),
  public.report_notifications(text), public.report_notifications_read(text, bigint[]),
  public.report_start(text),
  public.report_summary(text, date, date, bigint, bigint) from public;
grant execute on function
  public.reports_meta(text), public.report_list(text, jsonb),
  public.report_save(text, jsonb), public.report_review(text, bigint, text, text),
  public.report_delete(text, bigint), public.report_comments(text, bigint),
  public.report_comment_add(text, bigint, text), public.report_comment_delete(text, bigint),
  public.report_history(text, bigint), public.report_badge(text),
  public.report_notifications(text), public.report_notifications_read(text, bigint[]),
  public.report_start(text),
  public.report_summary(text, date, date, bigint, bigint) to anon, authenticated;

-- ===== migrations/20261116090000_daily_quick_entry.sql =====
-- Daily reports: quicker entry.
-- - report_save: "done_on" keeps the day work was done when it was saved
--   offline and sent later (up to 7 days back).
-- - report_withdraw: undo a submission that hasn't been reviewed yet.
-- - report_notifications: each carries its task, to open without a lookup.

alter table public.activity_changes
  drop constraint if exists activity_changes_action_check,
  add constraint activity_changes_action_check
    check (action in ('created', 'edited', 'deleted', 'submitted',
                      'approved', 'returned', 'withdrawn'));

create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  owner private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  v_for bigint := nullif(p_report->>'user_id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_status text := coalesce(nullif(p_report->>'status', ''), 'to_do');
  v_urgency text := coalesce(nullif(p_report->>'urgency', ''), 'normal');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_submit boolean := coalesce((p_report->>'submit')::boolean, false);
  v_title text := trim(coalesce(p_report->>'description', ''));
  v_dept bigint;
  v_assigned bigint;
  v_owner bigint;
  v_review text;
  v_report_date date;
  v_submitted timestamptz;
  -- Saved on a device while offline and sent later: the day it was done.
  v_done_on date := nullif(p_report->>'done_on', '')::date;
begin
  select * into u from private.app_users where id = me;
  if v_status not in ('to_do', 'in_progress', 'blocked', 'done') then
    raise exception 'bad_status' using errcode = '22023';
  end if;
  if v_urgency not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'bad_urgency' using errcode = '22023';
  end if;
  if length(v_title) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  if v_submit then v_status := 'done'; end if;

  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if not (before.user_id = me or before.assigned_by is not distinct from me or u.role = 'admin') then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    -- The owner can't change work once it is waiting for review or approved.
    if before.review in ('submitted', 'approved') and before.user_id = me
       and before.assigned_by is distinct from me and u.role is distinct from 'admin' then
      raise exception 'already_submitted' using errcode = '42501';
    end if;
    v_owner := before.user_id;
    v_assigned := before.assigned_by;
    -- Whoever assigned the task can hand it to someone else.
    if v_for is not null and v_for <> before.user_id
       and (before.assigned_by is not distinct from me or u.role = 'admin') then
      select * into owner from private.app_users where id = v_for and active;
      if owner.id is null then
        raise exception 'unknown_user' using errcode = '22023';
      end if;
      v_owner := owner.id;
    end if;
    v_dept := case when v_owner = before.user_id then before.department_id
                   else owner.department_id end;
  elsif v_for is not null and v_for <> me then
    if not private.can_assign(me) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    select * into owner from private.app_users where id = v_for and active;
    if owner.id is null then
      raise exception 'unknown_user' using errcode = '22023';
    end if;
    v_owner := owner.id;
    v_dept := owner.department_id;
    v_assigned := me;
    v_submit := false;
    if v_status = 'done' then v_status := 'to_do'; end if;
  else
    v_owner := me;
    v_dept := u.department_id;
  end if;

  if v_status = 'blocked' and length(trim(coalesce(p_report->>'blocker', ''))) = 0 then
    raise exception 'blocker_required' using errcode = '22023';
  end if;

  v_review := coalesce(before.review, 'none');
  v_report_date := before.report_date;
  v_submitted := before.submitted_at;
  if v_submit then
    if v_owner <> me then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_review := 'submitted';
    v_report_date := case
      when v_done_on between private.today() - 7 and private.today() then v_done_on
      else private.today() end;
    v_submitted := now();
  elsif v_status <> 'done' and v_review = 'approved' then
    v_review := 'none';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date,
        description, details, reference, outputs, status, blocker, urgency,
        due_date, assigned_by, review, submitted_at)
      values (v_owner, v_dept, v_report_date, left(v_title, 2000),
        left(trim(coalesce(p_report->>'details', '')), 4000),
        left(trim(coalesce(p_report->>'reference', '')), 200),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, left(trim(coalesce(p_report->>'blocker', '')), 1000), v_urgency,
        v_due, v_assigned, v_review, v_submitted)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
    if v_assigned is not null then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
    end if;
  else
    update public.activity_reports set
        user_id = v_owner,
        department_id = v_dept,
        report_date = v_report_date,
        description = left(v_title, 2000),
        details = left(trim(coalesce(p_report->>'details', '')), 4000),
        reference = left(trim(coalesce(p_report->>'reference', '')), 200),
        outputs = private.clean_outputs(p_report->'outputs', v_dept, before.outputs),
        status = v_status,
        blocker = case when v_status = 'blocked'
                       then left(trim(coalesce(p_report->>'blocker', '')), 1000) else '' end,
        urgency = v_urgency,
        due_date = v_due,
        review = v_review,
        submitted_at = v_submitted,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, case when v_submit then 'submitted' else 'edited' end,
              to_jsonb(before), to_jsonb(saved));
    if saved.user_id <> before.user_id then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
      perform private.notify(before.user_id, 'reassigned', saved.id, me, saved.description);
    elsif before.assigned_by is not distinct from me and saved.user_id <> me
          and (saved.urgency <> before.urgency or saved.due_date is distinct from before.due_date
               or saved.description <> before.description) then
      perform private.notify(saved.user_id, 'assigned', saved.id, me,
        'Updated: ' || saved.description);
    end if;
    if saved.status = 'blocked' and before.status <> 'blocked' then
      perform private.notify(saved.assigned_by, 'blocked', saved.id, me, saved.blocker);
    end if;
  end if;

  if v_submit then
    insert into public.report_comments (report_id, user_id, kind, body)
      values (saved.id, me, 'submitted', left(trim(coalesce(p_report->>'note', '')), 1000));
    perform private.notify(saved.assigned_by, 'submitted', saved.id, me, saved.description);
  end if;
  return private.report_json(saved);
end $$;

create or replace function public.report_withdraw(p_token text, p_report bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  saved public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if r.user_id is distinct from me then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if r.review <> 'submitted' then
    raise exception 'not_submitted' using errcode = '22023';
  end if;
  update public.activity_reports set
      -- Back to how it was: returned work stays returned.
      review = case when (select c.kind from public.report_comments c
                          where c.report_id = p_report
                            and c.kind in ('approved', 'returned')
                          order by c.id desc limit 1) = 'returned'
                    then 'returned' else 'none' end,
      status = 'in_progress', report_date = null,
      submitted_at = null, updated_at = now()
    where id = p_report
    returning * into saved;
  -- The submission's timeline entry and its unread notice go too.
  delete from public.report_comments
    where id = (select max(id) from public.report_comments
                where report_id = p_report and kind = 'submitted');
  delete from public.report_notifications
    where report_id = p_report and kind = 'submitted' and read_at is null;
  insert into public.activity_changes (report_id, changed_by, action, before, after)
    values (p_report, me, 'withdrawn', to_jsonb(r), to_jsonb(saved));
  return private.report_json(saved);
end $$;

create or replace function public.report_notifications(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'report_id', n.report_id, 'body', n.body,
      'created_at', n.created_at, 'read', n.read_at is not null,
      'actor_name', (select full_name from private.app_users where id = n.actor_id),
      'task', (select description from public.activity_reports where id = n.report_id),
      'urgency', (select urgency from public.activity_reports where id = n.report_id),
      -- The task itself, so tapping the notification opens it at once.
      'report', (select private.report_json(r) from public.activity_reports r
                 where r.id = n.report_id and private.can_see_task(me, r)))
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n), '[]'::jsonb);
end $$;

grant execute on function public.report_withdraw(text, bigint) to anon, authenticated;

-- ===== migrations/20261117090000_returned_not_counted.sql =====
-- Returned tasks no longer count as submitted: Team figures, "who has
-- reported" and department totals only count work that is waiting for
-- review or approved. The date is set again when it is resubmitted.

create or replace function public.report_review(p_token text, p_report bigint,
    p_decision text, p_comment text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  saved public.activity_reports;
  v_note text := left(trim(coalesce(p_comment, '')), 1000);
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_review(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'returned') then
    raise exception 'bad_decision' using errcode = '22023';
  end if;
  if r.review <> 'submitted' and not (r.review in ('approved', 'returned')
                                      and r.reviewed_by is not distinct from me) then
    raise exception 'not_submitted' using errcode = '22023';
  end if;
  if p_decision = 'returned' and length(v_note) = 0 then
    raise exception 'comment_required' using errcode = '22023';
  end if;
  update public.activity_reports set
      review = p_decision,
      status = case when p_decision = 'returned' then 'in_progress' else 'done' end,
      -- Returned work isn't a submission any more: it counts again (for the
      -- day it is resubmitted) only when it is resubmitted.
      report_date = case when p_decision = 'returned' then null
                         else coalesce(r.report_date, private.today()) end,
      reviewed_by = me, reviewed_at = now(), updated_at = now()
    where id = p_report
    returning * into saved;
  insert into public.report_comments (report_id, user_id, kind, body)
    values (p_report, me, p_decision, v_note);
  insert into public.activity_changes (report_id, changed_by, action, before, after)
    values (p_report, me, p_decision, to_jsonb(r), to_jsonb(saved));
  perform private.notify(saved.user_id, p_decision, saved.id, me,
    case when v_note = '' then saved.description else v_note end);
  return private.report_json(saved);
end $$;

update public.activity_reports
   set report_date = null
 where review = 'returned' and report_date is not null;

-- ===== migrations/20261118090000_personal_todos.sql =====
-- Personal to-do lists, kept per account so every device signed in as the
-- same person shows the same list. Only reachable through the two
-- functions below (the signed-in person's token decides whose list).
--
-- Each item carries the time the app last changed it; a save only replaces
-- an item when it is newer, so two devices editing different items never
-- undo each other. Deleted items are kept briefly as "deleted" so a device
-- that was offline doesn't bring them back.

create table if not exists public.todo_items (
  user_id bigint not null references private.app_users(id) on delete cascade,
  id bigint not null,
  title text not null check (length(title) between 1 and 300),
  done boolean not null default false,
  done_at timestamptz,
  sent_id bigint,
  deleted boolean not null default false,
  changed_at timestamptz not null,
  primary key (user_id, id)
);
alter table public.todo_items enable row level security;
revoke all on public.todo_items from anon, authenticated;

-- The person's list (deleted items left out), oldest first.
create or replace function public.todo_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  delete from public.todo_items
    where user_id = me and deleted and changed_at < now() - interval '30 days';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
        'sent_id', t.sent_id, 'changed_at', t.changed_at)
      order by t.id)
    from public.todo_items t
    where t.user_id = me and not t.deleted), '[]'::jsonb);
end $$;

-- Saves changed items: [{id, title, done, done_at, sent_id, deleted,
-- changed_at}]. Returns the list as it now stands.
create or replace function public.todo_save(p_token text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  n int;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
    where user_id = me and not deleted;
  if n + jsonb_array_length(p_items) > 2000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         -- A clock far ahead can't pin an item forever.
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes')
    from jsonb_array_elements(p_items) i
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at
    where excluded.changed_at >= t.changed_at;

  return public.todo_list(p_token);
end $$;

revoke all on function public.todo_list(text) from public;
revoke all on function public.todo_save(text, jsonb) from public;
grant execute on function public.todo_list(text) to anon, authenticated;
grant execute on function public.todo_save(text, jsonb) to anon, authenticated;

-- ===== migrations/20261119090000_todo_more.sql =====
-- To-do, round two:
--  * items keep their extra details (planned day, deadline, star, order,
--    repeat, notes, steps, counts, client link, who gave it…) in "extra";
--  * each department has a shared list everyone in it can see and tick;
--  * a to-do can be given to a colleague (it lands on their list);
--  * an item sent to Daily reports ticks itself once that task is done,
--    and shows how the task is doing (awaiting review, approved…).
-- todo_list / todo_save stay as they were for 1.7.0 apps; newer apps use
-- todo_sync.

alter table public.todo_items
  add column if not exists extra jsonb not null default '{}'::jsonb;

create table if not exists public.todo_team_items (
  department_id bigint not null references public.departments(id) on delete cascade,
  id bigint not null,
  title text not null check (length(title) between 1 and 300),
  done boolean not null default false,
  done_at timestamptz,
  deleted boolean not null default false,
  changed_at timestamptz not null,
  changed_by bigint references private.app_users(id) on delete set null,
  extra jsonb not null default '{}'::jsonb,
  primary key (department_id, id)
);
alter table public.todo_team_items enable row level security;
revoke all on public.todo_team_items from anon, authenticated;

-- Extra details are the app's; only their size is checked.
create or replace function private.todo_extra(p jsonb)
returns jsonb language sql immutable set search_path to '' as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then '{}'::jsonb
    when length(p::text) > 20000 then '{}'::jsonb
    else p end
$$;

create or replace function public.todo_sync(p_token text, p_items jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_dept bigint;
  n int;
begin
  select department_id into v_dept from private.app_users where id = me;
  if p_items is null then p_items := '[]'::jsonb; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items where user_id = me and not deleted;
  if n + jsonb_array_length(p_items) > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  -- My own items.
  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at, extra)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes'),
         private.todo_extra(i->'extra')
    from jsonb_array_elements(p_items) i
   where not coalesce((i->>'team')::boolean, false)
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at,
        extra = excluded.extra
    where excluded.changed_at >= t.changed_at;

  -- The department's shared list.
  if v_dept is not null then
    insert into public.todo_team_items as t
        (department_id, id, title, done, done_at, deleted, changed_at,
         changed_by, extra)
    select v_dept,
           (i->>'id')::bigint,
           left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
           coalesce((i->>'done')::boolean, false),
           (i->>'done_at')::timestamptz,
           coalesce((i->>'deleted')::boolean, false),
           least(coalesce((i->>'changed_at')::timestamptz, now()),
                 now() + interval '5 minutes'),
           me,
           private.todo_extra(i->'extra')
      from jsonb_array_elements(p_items) i
     where coalesce((i->>'team')::boolean, false)
    on conflict (department_id, id) do update
      set title = excluded.title,
          done = excluded.done,
          done_at = excluded.done_at,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at,
          changed_by = excluded.changed_by,
          extra = excluded.extra
      where excluded.changed_at >= t.changed_at;
  end if;

  -- Sent to Daily reports and finished there: ticked here too (once, so
  -- unticking it again sticks).
  update public.todo_items t
     set done = true,
         done_at = coalesce(t.done_at, now()),
         changed_at = now(),
         extra = t.extra || '{"auto_ticked": true}'::jsonb
    from public.activity_reports r
   where t.user_id = me and not t.done and not t.deleted
     and not (t.extra ? 'auto_ticked')
     and r.id = t.sent_id and r.user_id = me
     and r.status = 'done' and r.review in ('submitted', 'approved');

  -- Old deletions and long-cleared items go.
  delete from public.todo_items
   where user_id = me and (
     (deleted and changed_at < now() - interval '30 days') or
     (done and coalesce((extra->>'archived')::boolean, false)
      and done_at < now() - interval '90 days'));
  if v_dept is not null then
    delete from public.todo_team_items
     where department_id = v_dept and (
       (deleted and changed_at < now() - interval '30 days') or
       (done and done_at < now() - interval '90 days'));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
          'sent_id', t.sent_id, 'changed_at', t.changed_at, 'extra', t.extra,
          'report_review', r.review, 'report_status', r.status)
        order by t.id)
      from public.todo_items t
      left join public.activity_reports r
        on r.id = t.sent_id and r.user_id = me
      where t.user_id = me and not t.deleted), '[]'::jsonb),
    'team', case when v_dept is null then null else jsonb_build_object(
      'id', v_dept,
      'name', (select d.name from public.departments d where d.id = v_dept),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id, 'title', t.title, 'done', t.done,
            'done_at', t.done_at, 'changed_at', t.changed_at,
            'extra', t.extra, 'team', true,
            'changed_by_name', u.full_name)
          order by t.id)
        from public.todo_team_items t
        left join private.app_users u on u.id = t.changed_by
        where t.department_id = v_dept and not t.deleted), '[]'::jsonb))
    end);
end $$;

-- Who a to-do can be given to: everyone else with an active account.
create or replace function public.todo_people(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', u.id, 'name', u.full_name, 'department', d.name)
      order by lower(u.full_name))
    from private.app_users u
    left join public.departments d on d.id = u.department_id
    where u.active and u.id <> me), '[]'::jsonb);
end $$;

-- Puts a to-do on a colleague's list, marked as from me (and new).
create or replace function public.todo_give(p_token text, p_user bigint, p_item jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_name text;
  v_title text := left(trim(coalesce(p_item->>'title', '')), 300);
  n int;
begin
  if length(v_title) = 0 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if not exists (select 1 from private.app_users where id = p_user and active)
     or p_user = me then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
   where user_id = p_user and not deleted;
  if n >= 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;
  select full_name into v_name from private.app_users where id = me;
  insert into public.todo_items (user_id, id, title, changed_at, extra)
  values (
    p_user,
    (extract(epoch from clock_timestamp()) * 1000000)::bigint
      + floor(random() * 1000)::bigint,
    v_title,
    now(),
    private.todo_extra(
      jsonb_strip_nulls(jsonb_build_object(
        'notes', left(p_item->>'notes', 2000),
        'day', p_item->'day',
        'due', p_item->'due',
        'starred', p_item->'starred',
        'steps', p_item->'steps',
        'client', p_item->'client'))
      || jsonb_build_object(
        'from', jsonb_build_object('id', me, 'name', v_name),
        'new', true)))
  on conflict do nothing;
end $$;

revoke all on function public.todo_sync(text, jsonb) from public;
revoke all on function public.todo_people(text) from public;
revoke all on function public.todo_give(text, bigint, jsonb) from public;
revoke all on function private.todo_extra(jsonb) from public;
grant execute on function public.todo_sync(text, jsonb) to anon, authenticated;
grant execute on function public.todo_people(text) to anon, authenticated;
grant execute on function public.todo_give(text, bigint, jsonb) to anon, authenticated;

-- ===== migrations/20261120090000_review_fixes.sql =====
-- Fixes from the November security and bug review (findings in brackets).
-- Safe to run more than once.

-- ---------------------------------------------------------------------
-- [3] A temporary password gives a sign-in that can only choose a new
-- password (or sign out). Every other function refuses it. A switched-off
-- account's sign-ins are refused everywhere, not only where token_user
-- was used.

-- Any live sign-in, temporary or not: for choosing the new password,
-- checking the sign-in and signing out.
create or replace function private.token_user_any(p_token text)
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

create or replace function private.token_user(p_token text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid bigint;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  select t.user_id into uid
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active and not u.must_change
    where t.token_hash = h and t.expires_at > now();
  if uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return uid;
end $$;

create or replace function private.token_role(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  r text;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  -- Old shared-profile sign-ins have no account (user_id is null).
  select t.role into r
    from private.admin_tokens t
    left join private.app_users u on u.id = t.user_id
    where t.token_hash = h and t.expires_at > now()
      and (t.user_id is null or (u.active and not u.must_change));
  if r is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return r;
end $$;

create or replace function public.user_session(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.token_user_any(p_token);
begin
  update private.admin_tokens
    set expires_at = now() + case when remember then interval '30 days' else interval '1 day' end
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  return private.user_json(uid);
end $$;

create or replace function public.user_change_password(p_token text, p_current text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user_any(p_token);
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

create or replace function public.user_session_touch(p_token text, p_device text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.token_user_any(p_token);
  update private.admin_tokens
    set device = left(nullif(trim(coalesce(p_device, '')), ''), 80),
        last_seen = now()
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- ---------------------------------------------------------------------
-- [2] Page access is enforced here too: data for a page an account may
-- not open is not sent to it, and changes to it are refused.

-- The pages the sign-in's account may open (null: all of them).
create or replace function private.token_pages(p_token text)
returns text[] language sql stable security definer set search_path = '' as $$
  select u.pages
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id
    where t.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- Which pages show each synced table.
create or replace function private.table_pages(p_table text)
returns text[] language sql immutable set search_path = '' as $$
  select case
    when p_table in ('revenue_entries', 'revenue_changes') then array['revenue']
    when p_table in ('applications', 'application_imports', 'application_changes')
      then array['applications', 'home', 'reports']
    when p_table = 'app_settings' then null
    else array['home', 'week', 'history', 'staff', 'reports'] end;
$$;

create or replace function private.may_sync(p_pages text[], p_table text)
returns boolean language sql immutable set search_path = '' as $$
  select p_pages is null or private.table_pages(p_table) is null
      or p_pages && private.table_pages(p_table);
$$;

create or replace function public.sync_read(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  pg text[] := private.token_pages(p_token);
  money boolean := r in ('admin', 'director') and private.may_sync(pg, 'revenue_entries');
  tracker boolean := private.may_sync(pg, 'client_counts');
  apps boolean := private.may_sync(pg, 'applications');
begin
  return jsonb_build_object(
    'staff',           case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]') else '[]' end,
    'weeks',           case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]') else '[]' end,
    'work_days',       case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]') else '[]' end,
    'client_counts',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]') else '[]' end,
    'staff_day_off',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]') else '[]' end,
    'day_notes',       case when tracker then coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]') else '[]' end,
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]') else '[]' end,
    'revenue_entries', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]') else '[]' end,
    'revenue_changes', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_changes t), '[]') else '[]' end,
    'applications',        case when apps then coalesce((select jsonb_agg(t order by t.id) from public.applications t), '[]') else '[]' end,
    'application_imports', case when apps then coalesce((select jsonb_agg(t order by t.id) from public.application_imports t), '[]') else '[]' end,
    'application_changes', case when apps then coalesce((select jsonb_agg(t order by t.id) from public.application_changes t), '[]') else '[]' end
  );
end $$;

-- ---------------------------------------------------------------------
-- [11] A row older than the one online no longer replaces it: on tables
-- that keep updated_at, the newest edit of a row wins, whichever device
-- sends it last. The sender's next download brings the newer row back.
create or replace function private.upsert_rows(p_table text, p_pk text, p_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sets text;
  newer text := '';
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then return; end if;
  select string_agg(format('%I = excluded.%I', column_name, column_name), ', ')
    into sets
    from information_schema.columns
    where table_schema = 'public' and table_name = p_table
      and column_name <> p_pk;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = p_table
               and column_name = 'updated_at') then
    newer := ' where excluded.updated_at >= t.updated_at';
  end if;
  execute format(
    'insert into public.%I as t select * from jsonb_populate_recordset(null::public.%I, $1) '
    'on conflict (%I) do update set %s%s',
    p_table, p_table, p_pk, sets, newer) using p_rows;
end $$;

-- [12] Rows that another device already made under another id (the same
-- week, day, or person's count for a day) take the id that is online, so
-- the upload goes through and both devices end with the same rows.
create or replace function private.remap(p_rows jsonb, p_col text, p_map jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(case
      when p_map ? (r->>p_col)
        then jsonb_set(r, array[p_col], to_jsonb((p_map->>(r->>p_col))::bigint))
      else r end), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;
$$;

create or replace function private.canonical_ids(p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  up jsonb := coalesce(p_payload->'upserts', '{}'::jsonb);
  wmap jsonb; dmap jsonb; cmap jsonb; omap jsonb;
  t text;
begin
  select coalesce(jsonb_object_agg(r->>'id', w.id), '{}') into wmap
    from jsonb_array_elements(coalesce(up->'weeks', '[]')) r
    join public.weeks w on w.start_date = r->>'start_date'
                       and w.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{weeks}', private.remap(up->'weeks', 'id', wmap));
  up := jsonb_set(up, '{work_days}', private.remap(up->'work_days', 'week_id', wmap));

  select coalesce(jsonb_object_agg(r->>'id', d.id), '{}') into dmap
    from jsonb_array_elements(coalesce(up->'work_days', '[]')) r
    join public.work_days d on d.date = r->>'date'
                           and d.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{work_days}', private.remap(up->'work_days', 'id', dmap));
  foreach t in array array['client_counts', 'staff_day_off', 'day_notes', 'count_changes'] loop
    up := jsonb_set(up, array[t], private.remap(up->t, 'day_id', dmap));
  end loop;

  select coalesce(jsonb_object_agg(r->>'id', c.id), '{}') into cmap
    from jsonb_array_elements(coalesce(up->'client_counts', '[]')) r
    join public.client_counts c on c.day_id = (r->>'day_id')::bigint
                               and c.staff_id = (r->>'staff_id')::bigint
                               and c.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{client_counts}', private.remap(up->'client_counts', 'id', cmap));

  select coalesce(jsonb_object_agg(r->>'id', o.id), '{}') into omap
    from jsonb_array_elements(coalesce(up->'staff_day_off', '[]')) r
    join public.staff_day_off o on o.day_id = (r->>'day_id')::bigint
                               and o.staff_id = (r->>'staff_id')::bigint
                               and o.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{staff_day_off}', private.remap(up->'staff_day_off', 'id', omap));

  return jsonb_set(p_payload, '{upserts}', up);
end $$;

-- [2] [4] [12] Changes: refused for pages the account may not open, and
-- the protected settings can be neither changed nor deleted by the admin
-- team.
create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes',
    'applications','application_imports','application_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id','id',
    'id','id','id'];
  r text := private.token_role(p_token);
  pg text[] := private.token_pages(p_token);
  i int;
  payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if r not in ('admin', 'admin_team') then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if r = 'admin_team' and (
       jsonb_array_length(coalesce(payload->'upserts'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'deletes'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'upserts'->'revenue_changes', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'deletes'->'revenue_changes', '[]')) > 0 or
       exists (select 1 from jsonb_array_elements(coalesce(payload->'upserts'->'app_settings', '[]')) e
               where e->>'key' in ('currency', 'revenue_purposes')) or
       exists (select 1 from jsonb_array_elements_text(coalesce(payload->'deletes'->'app_settings', '[]')) k
               where k in ('currency', 'revenue_purposes'))) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  for i in 1..array_length(tables, 1) loop
    if not private.may_sync(pg, tables[i]) and (
         jsonb_array_length(coalesce(payload->'upserts'->tables[i], '[]')) > 0 or
         jsonb_array_length(coalesce(payload->'deletes'->tables[i], '[]')) > 0) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
  end loop;
  payload := private.canonical_ids(payload);
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

-- ---------------------------------------------------------------------
-- [8] [17] Reports: a new report sent twice (the reply was lost) is saved
-- once; an approval only stands for what was approved.
alter table public.activity_reports add column if not exists client_op text;
create unique index if not exists activity_reports_client_op
  on public.activity_reports (client_op) where client_op is not null;

create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  owner private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  v_for bigint := nullif(p_report->>'user_id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_status text := coalesce(nullif(p_report->>'status', ''), 'to_do');
  v_urgency text := coalesce(nullif(p_report->>'urgency', ''), 'normal');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_submit boolean := coalesce((p_report->>'submit')::boolean, false);
  v_title text := trim(coalesce(p_report->>'description', ''));
  v_details text := left(trim(coalesce(p_report->>'details', '')), 4000);
  v_reference text := left(trim(coalesce(p_report->>'reference', '')), 200);
  v_outputs jsonb;
  v_op text := nullif(left(trim(coalesce(p_report->>'op', '')), 80), '');
  v_dept bigint;
  v_assigned bigint;
  v_owner bigint;
  v_review text;
  v_report_date date;
  v_submitted timestamptz;
  v_reviewed_by bigint;
  v_reviewed_at timestamptz;
  v_done_on date := nullif(p_report->>'done_on', '')::date;
begin
  select * into u from private.app_users where id = me;
  if rid is null and v_op is not null then
    -- Sent before (the reply never arrived): the same report again.
    v_op := me || ':' || v_op;
    select * into saved from public.activity_reports where client_op = v_op;
    if saved.id is not null then
      return private.report_json(saved);
    end if;
  end if;
  if v_status not in ('to_do', 'in_progress', 'blocked', 'done') then
    raise exception 'bad_status' using errcode = '22023';
  end if;
  if v_urgency not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'bad_urgency' using errcode = '22023';
  end if;
  if length(v_title) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  if v_submit then v_status := 'done'; end if;

  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if not (before.user_id = me or before.assigned_by is not distinct from me or u.role = 'admin') then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    if before.review in ('submitted', 'approved') and before.user_id = me
       and before.assigned_by is distinct from me and u.role is distinct from 'admin' then
      raise exception 'already_submitted' using errcode = '42501';
    end if;
    v_owner := before.user_id;
    v_assigned := before.assigned_by;
    if v_for is not null and v_for <> before.user_id
       and (before.assigned_by is not distinct from me or u.role = 'admin') then
      select * into owner from private.app_users where id = v_for and active;
      if owner.id is null then
        raise exception 'unknown_user' using errcode = '22023';
      end if;
      v_owner := owner.id;
    end if;
    v_dept := case when v_owner = before.user_id then before.department_id
                   else owner.department_id end;
  elsif v_for is not null and v_for <> me then
    if not private.can_assign(me) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    select * into owner from private.app_users where id = v_for and active;
    if owner.id is null then
      raise exception 'unknown_user' using errcode = '22023';
    end if;
    v_owner := owner.id;
    v_dept := owner.department_id;
    v_assigned := me;
    v_submit := false;
    if v_status = 'done' then v_status := 'to_do'; end if;
  else
    v_owner := me;
    v_dept := u.department_id;
  end if;

  if v_status = 'blocked' and length(trim(coalesce(p_report->>'blocker', ''))) = 0 then
    raise exception 'blocker_required' using errcode = '22023';
  end if;

  v_outputs := case when rid is null
    then private.clean_outputs(p_report->'outputs', v_dept)
    else private.clean_outputs(p_report->'outputs', v_dept, before.outputs) end;

  v_review := coalesce(before.review, 'none');
  v_report_date := before.report_date;
  v_submitted := before.submitted_at;
  v_reviewed_by := before.reviewed_by;
  v_reviewed_at := before.reviewed_at;
  if v_submit then
    if v_owner <> me then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_review := 'submitted';
    v_report_date := case
      when v_done_on between private.today() - 7 and private.today() then v_done_on
      else private.today() end;
    v_submitted := now();
    v_reviewed_by := null;
    v_reviewed_at := null;
  elsif rid is not null and v_review in ('submitted', 'approved') then
    if v_status <> 'done' or v_owner <> before.user_id then
      -- Reopened, or now someone else's: no longer a submission.
      v_review := 'none';
      v_report_date := null;
      v_submitted := null;
      v_reviewed_by := null;
      v_reviewed_at := null;
    elsif v_review = 'approved' and (
          left(v_title, 2000) <> before.description
          or v_details <> before.details
          or v_reference <> before.reference
          or v_outputs is distinct from before.outputs
          or v_dept is distinct from before.department_id) then
      -- Changed after approval: back for a fresh review.
      v_review := 'submitted';
      v_reviewed_by := null;
      v_reviewed_at := null;
    end if;
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date,
        description, details, reference, outputs, status, blocker, urgency,
        due_date, assigned_by, review, submitted_at, client_op)
      values (v_owner, v_dept, v_report_date, left(v_title, 2000),
        v_details, v_reference, v_outputs,
        v_status, left(trim(coalesce(p_report->>'blocker', '')), 1000), v_urgency,
        v_due, v_assigned, v_review, v_submitted, v_op)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
    if v_assigned is not null then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
    end if;
  else
    update public.activity_reports set
        user_id = v_owner,
        department_id = v_dept,
        report_date = v_report_date,
        description = left(v_title, 2000),
        details = v_details,
        reference = v_reference,
        outputs = v_outputs,
        status = v_status,
        blocker = case when v_status = 'blocked'
                       then left(trim(coalesce(p_report->>'blocker', '')), 1000) else '' end,
        urgency = v_urgency,
        due_date = v_due,
        review = v_review,
        submitted_at = v_submitted,
        reviewed_by = v_reviewed_by,
        reviewed_at = v_reviewed_at,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, case when v_submit then 'submitted' else 'edited' end,
              to_jsonb(before), to_jsonb(saved));
    if saved.user_id <> before.user_id then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
      perform private.notify(before.user_id, 'reassigned', saved.id, me, saved.description);
    elsif before.assigned_by is not distinct from me and saved.user_id <> me
          and (saved.urgency <> before.urgency or saved.due_date is distinct from before.due_date
               or saved.description <> before.description) then
      perform private.notify(saved.user_id, 'assigned', saved.id, me,
        'Updated: ' || saved.description);
    end if;
    if saved.status = 'blocked' and before.status <> 'blocked' then
      perform private.notify(saved.assigned_by, 'blocked', saved.id, me, saved.blocker);
    end if;
  end if;

  if v_submit then
    insert into public.report_comments (report_id, user_id, kind, body)
      values (saved.id, me, 'submitted', left(trim(coalesce(p_report->>'note', '')), 1000));
    perform private.notify(saved.assigned_by, 'submitted', saved.id, me, saved.description);
  end if;
  return private.report_json(saved);
end $$;

-- [13] A notification shows the task as it is now only to someone who may
-- still see it; others see what the notification said at the time.
create or replace function public.report_notifications(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'report_id', n.report_id, 'body', n.body,
      'created_at', n.created_at, 'read', n.read_at is not null,
      'actor_name', (select full_name from private.app_users where id = n.actor_id),
      'task', case when r.id is not null then r.description else n.body end,
      'urgency', r.urgency,
      'report', case when r.id is not null then private.report_json(r) end)
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n
    left join lateral (
      select x.* from public.activity_reports x
       where x.id = n.report_id and private.can_see_task(me, x)) r on true), '[]'::jsonb);
end $$;

-- [27] Lists can be read page by page (exports read every page).
create or replace function public.report_list(p_token text, p_filter jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_from date := nullif(f->>'from', '')::date;
  v_to date := nullif(f->>'to', '')::date;
  v_dept bigint := nullif(f->>'department_id', '')::bigint;
  v_user bigint := nullif(f->>'user_id', '')::bigint;
  v_statuses text[] := case when jsonb_typeof(f->'statuses') = 'array'
    then array(select jsonb_array_elements_text(f->'statuses')) end;
  v_reviews text[] := case when jsonb_typeof(f->'reviews') = 'array'
    then array(select jsonb_array_elements_text(f->'reviews')) end;
  v_urgency text := nullif(f->>'urgency', '');
  v_open boolean := coalesce((f->>'open_only')::boolean, false);
  v_overdue boolean := coalesce((f->>'overdue_only')::boolean, false);
  v_assigned_by_me boolean := coalesce((f->>'assigned_by_me')::boolean, false);
  v_to_review boolean := coalesce((f->>'to_review')::boolean, false);
  v_reviewed_by_me boolean := coalesce((f->>'reviewed_by_me')::boolean, false);
  v_search text := nullif(trim(coalesce(f->>'search', '')), '');
  v_id bigint := case when v_search ~ '^#?[0-9]{1,12}$'
    then ltrim(v_search, '#')::bigint end;
  v_limit int := least(greatest(coalesce((f->>'limit')::int, 500), 1), 3000);
  v_offset int := greatest(coalesce((f->>'offset')::int, 0), 0);
begin
  return coalesce((
    select jsonb_agg(private.report_json(r) order by
        coalesce(r.submitted_at, r.updated_at) desc, r.id desc)
    from (
      select * from public.activity_reports r
      where private.can_see_task(me, r)
        and (v_from is null or r.report_date >= v_from)
        and (v_to is null or r.report_date <= v_to)
        and (v_dept is null or r.department_id = v_dept)
        and (v_user is null or r.user_id = v_user)
        and (v_statuses is null or r.status = any(v_statuses))
        and (v_reviews is null or r.review = any(v_reviews))
        and (v_urgency is null or r.urgency = v_urgency)
        and (not v_open or r.status <> 'done' or r.review = 'returned')
        and (not v_overdue or (r.status <> 'done' and r.due_date < private.today()))
        and (not v_assigned_by_me or r.assigned_by is not distinct from me)
        and (not v_to_review or (r.review = 'submitted' and private.can_review(me, r)))
        and (not v_reviewed_by_me or r.reviewed_by = me)
        and (v_search is null or r.id = v_id or private.search_hit(v_search,
              concat_ws(' ', r.description, r.details, r.reference, r.blocker,
                (select full_name from private.app_users where id = r.user_id),
                (select full_name from private.app_users where id = r.assigned_by),
                (select name from public.departments where id = r.department_id))))
      order by coalesce(r.submitted_at, r.updated_at) desc, r.id desc
      limit v_limit offset v_offset
    ) r), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- [23] To-do details are checked field by field: anything of the wrong
-- kind is left out, so no item can break someone's list.
create or replace function private.todo_extra(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  o jsonb := '{}'::jsonb;
  steps jsonb := '[]'::jsonb;
  outs jsonb := '{}'::jsonb;
  s jsonb;
  k text;
  v jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' or length(p::text) > 20000 then
    return '{}'::jsonb;
  end if;
  foreach k in array array['notes', 'day', 'due', 'repeat', 'done_by'] loop
    if jsonb_typeof(p->k) = 'string' then
      o := o || jsonb_build_object(k, left(p->>k, case k when 'notes' then 4000 else 60 end));
    end if;
  end loop;
  foreach k in array array['later', 'starred', 'new', 'archived', 'auto_ticked'] loop
    if jsonb_typeof(p->k) = 'boolean' then o := o || jsonb_build_object(k, p->k); end if;
  end loop;
  foreach k in array array['pos', 'spawned'] loop
    if jsonb_typeof(p->k) = 'number' then o := o || jsonb_build_object(k, p->k); end if;
  end loop;
  if jsonb_typeof(p->'steps') = 'array' then
    for s in select value from jsonb_array_elements(p->'steps') limit 100 loop
      if jsonb_typeof(s) = 'object' and jsonb_typeof(s->'t') = 'string' then
        steps := steps || jsonb_build_array(
          jsonb_build_object('t', left(s->>'t', 300))
          || case when s->'d' = 'true'::jsonb then '{"d": true}'::jsonb else '{}'::jsonb end);
      end if;
    end loop;
    if jsonb_array_length(steps) > 0 then o := o || jsonb_build_object('steps', steps); end if;
  end if;
  if jsonb_typeof(p->'outputs') = 'object' then
    for k, v in select key, value from jsonb_each(p->'outputs') limit 50 loop
      if jsonb_typeof(v) = 'number' then
        outs := outs || jsonb_build_object(left(k, 60), v);
      end if;
    end loop;
    if outs <> '{}'::jsonb then o := o || jsonb_build_object('outputs', outs); end if;
  end if;
  if jsonb_typeof(p->'client') = 'object' and jsonb_typeof(p->'client'->'key') = 'string' then
    o := o || jsonb_build_object('client', jsonb_build_object(
      'key', left(p->'client'->>'key', 200),
      'name', left(case when jsonb_typeof(p->'client'->'name') = 'string'
                        then p->'client'->>'name' else p->'client'->>'key' end, 200)));
  end if;
  if jsonb_typeof(p->'from') = 'object' and jsonb_typeof(p->'from'->'name') = 'string' then
    o := o || jsonb_build_object('from', jsonb_strip_nulls(jsonb_build_object(
      'id', case when jsonb_typeof(p->'from'->'id') = 'number' then p->'from'->'id' end,
      'name', left(p->'from'->>'name', 200))));
  end if;
  return o;
end $$;

-- Already saved: cleaned the same way.
update public.todo_items set extra = private.todo_extra(extra)
  where extra is distinct from private.todo_extra(extra);
update public.todo_team_items set extra = private.todo_extra(extra)
  where extra is distinct from private.todo_extra(extra);

-- [9] [18] The item limit counts what the list would hold after the
-- change (so deleting and editing always work), and a shared item is
-- only saved to the department it came from.
create or replace function public.todo_sync(p_token text, p_items jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  v_dept bigint;
  n int;
  v_added int;
begin
  select department_id into v_dept from private.app_users where id = me;
  if p_items is null then p_items := '[]'::jsonb; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items where user_id = me and not deleted;
  select count(*) filter (where not coalesce((i->>'deleted')::boolean, false) and t.id is null)
       - count(*) filter (where coalesce((i->>'deleted')::boolean, false) and t.id is not null)
    into v_added
    from jsonb_array_elements(p_items) i
    left join public.todo_items t
      on t.user_id = me and t.id = (i->>'id')::bigint and not t.deleted
   where not coalesce((i->>'team')::boolean, false);
  if v_added > 0 and n + v_added > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at, extra)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes'),
         private.todo_extra(i->'extra')
    from jsonb_array_elements(p_items) i
   where not coalesce((i->>'team')::boolean, false)
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at,
        extra = excluded.extra
    where excluded.changed_at >= t.changed_at;

  if v_dept is not null then
    insert into public.todo_team_items as t
        (department_id, id, title, done, done_at, deleted, changed_at,
         changed_by, extra)
    select v_dept,
           (i->>'id')::bigint,
           left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
           coalesce((i->>'done')::boolean, false),
           (i->>'done_at')::timestamptz,
           coalesce((i->>'deleted')::boolean, false),
           least(coalesce((i->>'changed_at')::timestamptz, now()),
                 now() + interval '5 minutes'),
           me,
           private.todo_extra(i->'extra')
      from jsonb_array_elements(p_items) i
     where coalesce((i->>'team')::boolean, false)
       and jsonb_typeof(i->'dept') = 'number'
       and (i->>'dept')::bigint = v_dept
    on conflict (department_id, id) do update
      set title = excluded.title,
          done = excluded.done,
          done_at = excluded.done_at,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at,
          changed_by = excluded.changed_by,
          extra = excluded.extra
      where excluded.changed_at >= t.changed_at;
  end if;

  update public.todo_items t
     set done = true,
         done_at = coalesce(t.done_at, now()),
         changed_at = now(),
         extra = t.extra || '{"auto_ticked": true}'::jsonb
    from public.activity_reports r
   where t.user_id = me and not t.done and not t.deleted
     and not (t.extra ? 'auto_ticked')
     and r.id = t.sent_id and r.user_id = me
     and r.status = 'done' and r.review in ('submitted', 'approved');

  delete from public.todo_items
   where user_id = me and (
     (deleted and changed_at < now() - interval '30 days') or
     (done and coalesce((extra->>'archived')::boolean, false)
      and done_at < now() - interval '90 days'));
  if v_dept is not null then
    delete from public.todo_team_items
     where department_id = v_dept and (
       (deleted and changed_at < now() - interval '30 days') or
       (done and done_at < now() - interval '90 days'));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
          'sent_id', t.sent_id, 'changed_at', t.changed_at, 'extra', t.extra,
          'report_review', r.review, 'report_status', r.status)
        order by t.id)
      from public.todo_items t
      left join public.activity_reports r
        on r.id = t.sent_id and r.user_id = me
      where t.user_id = me and not t.deleted), '[]'::jsonb),
    'team', case when v_dept is null then null else jsonb_build_object(
      'id', v_dept,
      'name', (select d.name from public.departments d where d.id = v_dept),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id, 'title', t.title, 'done', t.done,
            'done_at', t.done_at, 'changed_at', t.changed_at,
            'extra', t.extra, 'team', true, 'dept', v_dept,
            'changed_by_name', u.full_name)
          order by t.id)
        from public.todo_team_items t
        left join private.app_users u on u.id = t.changed_by
        where t.department_id = v_dept and not t.deleted), '[]'::jsonb))
    end);
end $$;

-- The older save (before 1.8): the same limit rule.
create or replace function public.todo_save(p_token text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  n int;
  v_added int;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
    where user_id = me and not deleted;
  select count(*) filter (where not coalesce((i->>'deleted')::boolean, false) and t.id is null)
       - count(*) filter (where coalesce((i->>'deleted')::boolean, false) and t.id is not null)
    into v_added
    from jsonb_array_elements(p_items) i
    left join public.todo_items t
      on t.user_id = me and t.id = (i->>'id')::bigint and not t.deleted;
  if v_added > 0 and n + v_added > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes')
    from jsonb_array_elements(p_items) i
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at
    where excluded.changed_at >= t.changed_at;

  return public.todo_list(p_token);
end $$;

-- ---------------------------------------------------------------------
-- [14] [19] The online backup holds the to-do lists too, and a restore
-- no longer fails because someone named in an old backup has since been
-- deleted (their name is left blank on what they did).
create or replace function public.admin_backup(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  return jsonb_build_object(
    'departments', coalesce((select jsonb_agg(t order by t.id) from public.departments t), '[]'),
    'activity_reports', coalesce((select jsonb_agg(t order by t.id) from public.activity_reports t), '[]'),
    'activity_changes', coalesce((select jsonb_agg(t order by t.id) from public.activity_changes t), '[]'),
    'report_comments', coalesce((select jsonb_agg(t order by t.id) from public.report_comments t), '[]'),
    'todo_items', coalesce((select jsonb_agg(t order by t.user_id, t.id) from public.todo_items t), '[]'),
    'todo_team_items', coalesce((select jsonb_agg(t order by t.department_id, t.id) from public.todo_team_items t), '[]'),
    'accounts', coalesce((select jsonb_agg(private.user_json(u.id) order by u.id) from private.app_users u), '[]'),
    'audit_log', coalesce((select jsonb_agg(t order by t.id) from private.audit_log t), '[]')
  );
end $$;

-- An account id that still exists, or null.
create or replace function private.known_user(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number'
               and exists (select 1 from private.app_users where id = (p #>> '{}')::bigint)
              then p else 'null'::jsonb end;
$$;

create or replace function public.admin_restore_online(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_dept int; n_rep int; n_chg int; n_com int; n_todo int; n_team int;
begin
  perform private.check_token(p_token);
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

-- ---------------------------------------------------------------------
-- [16] Airtable calls made before a failure stay counted: the count goes
-- with the error and is added back after the failed part is undone.
create or replace function private.airtable_fetch(p_full boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  s private.airtable_state;
  v_started timestamptz := now();
  v_path text;
  v_offset text;
  v_resp jsonb;
  v_status int;
  v_calls int := 0;
  v_read int := 0;
  v_pos int := 0;
  v_next_pos int;
  v_fields text := '';
  v_seen text[] := '{}';
  rec jsonb;
  f text;
  v_msg text;
  v_detail text;
begin
  select * into c from private.airtable_config where id = 1;
  select * into s from private.airtable_state where id = 1;
  for f in select value from jsonb_each_text(c.fields) loop
    v_fields := v_fields || '&fields%5B%5D=' || f;
  end loop;
  if not p_full and s.cursor_at is null then
    p_full := true;                    -- never read: read everything
  end if;
  select coalesce(max(position), -1) + 1 into v_next_pos from private.airtable_records;

  begin
    loop
      v_path := c.base_id || '/' || c.table_id || '?view=' || c.view_id
        || '&pageSize=100&returnFieldsByFieldId=true' || v_fields;
      if not p_full then
        -- A minute's overlap, so a change made during the last read is caught.
        v_path := v_path || '&filterByFormula=' || extensions.urlencode(format(
          'IS_AFTER(LAST_MODIFIED_TIME(), ''%s'')',
          to_char((s.cursor_at - interval '1 minute') at time zone 'UTC',
                  'YYYY-MM-DD"T"HH24:MI:SS.000"Z"')));
      end if;
      if v_offset is not null then
        v_path := v_path || '&offset=' || extensions.urlencode(v_offset);
      end if;
      v_calls := v_calls + 1;          -- counted before: a call that fails still counts
      v_resp := private.airtable_get(v_path);
      v_status := (v_resp->>'status')::int;
      if v_status <> 200 then
        raise exception '%', case
          when v_status in (401, 403) then 'airtable_token_rejected'
          when v_status = 404 then 'airtable_not_found'
          when v_status = 429 then 'airtable_limit'
          else 'airtable_error_' || v_status end
          using errcode = 'P0001',
                detail = coalesce(v_resp->'body'->'error'->>'message',
                                  v_resp->'body'->>'error', '');
      end if;
      for rec in select value from jsonb_array_elements(v_resp->'body'->'records') loop
        v_read := v_read + 1;
        v_seen := v_seen || (rec->>'id');
        if p_full then
          insert into private.airtable_records as r (rec_id, fields, position, read_at)
            values (rec->>'id', coalesce(rec->'fields', '{}'), v_pos, v_started)
            on conflict (rec_id) do update
              set fields = excluded.fields, position = excluded.position, read_at = excluded.read_at;
          v_pos := v_pos + 1;
        else
          insert into private.airtable_records as r (rec_id, fields, position, read_at)
            values (rec->>'id', coalesce(rec->'fields', '{}'), v_next_pos, v_started)
            on conflict (rec_id) do update
              set fields = excluded.fields, read_at = excluded.read_at;
          if found then v_next_pos := v_next_pos + 1; end if;
        end if;
      end loop;
      v_offset := v_resp->'body'->>'offset';
      exit when v_offset is null;
      if v_calls >= 20 then              -- 2,000 records: something's wrong
        raise exception 'airtable_too_many_pages' using errcode = 'P0001';
      end if;
      perform pg_sleep(0.25);            -- Airtable: at most 5 calls a second
    end loop;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    raise exception '%', v_msg
      using errcode = 'P0001', detail = coalesce(v_detail, ''),
            hint = 'airtable_calls=' || v_calls;
  end;

  if p_full then
    delete from private.airtable_records where not (rec_id = any (v_seen));
  end if;
  update private.airtable_state
    set cursor_at = v_started,
        last_full_at = case when p_full then v_started else last_full_at end
    where id = 1;
  return jsonb_build_object('calls', v_calls, 'read', v_read, 'full', p_full);
end $$;

create or replace function private.airtable_run(p_kind text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_fetch jsonb;
  v_apply jsonb;
  v_result jsonb;
  v_code text;
  v_detail text;
  v_hint text;
  v_calls int := 0;
begin
  if not coalesce((select enabled from private.airtable_config where id = 1), false) then
    return jsonb_build_object('skipped', 'disabled');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('airtable_sync')) then
    return jsonb_build_object('skipped', 'busy');
  end if;
  update private.airtable_state set last_run_at = now(), last_kind = p_kind where id = 1;
  begin
    v_fetch := private.airtable_fetch(p_kind = 'full');
    v_apply := private.applications_apply(p_label);
    v_result := v_apply || v_fetch;
    update private.airtable_state
      set last_ok_at = now(), last_result = v_result, last_error = null
      where id = 1;
    return v_result;
  exception when others then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail,
                            v_hint = pg_exception_hint;
    -- The failure undid the counting too: add back every call made, from
    -- the fetch's result (it finished; the next step failed) or the error.
    if v_fetch is not null then
      v_calls := coalesce((v_fetch->>'calls')::int, 0);
    elsif coalesce(v_hint, '') like 'airtable_calls=%' then
      v_calls := coalesce(nullif(substring(v_hint from '[0-9]+'), '')::int, 0);
    end if;
    if v_calls > 0 then
      insert into private.airtable_usage as u (month, calls)
        values (date_trunc('month', now() at time zone 'Africa/Nairobi')::date, v_calls)
        on conflict (month) do update set calls = u.calls + v_calls;
    end if;
    update private.airtable_state
      set last_error = v_code || case when coalesce(v_detail, '') <> ''
                                      then ': ' || v_detail else '' end,
          last_error_at = now()
      where id = 1;
    return jsonb_build_object('error', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- [24] Error reports: reports from signed-in people have their own daily
-- room, so reports sent without signing in can't use it all up; and one
-- sender without a sign-in can add only a few new kinds a day.
alter table private.error_reports add column if not exists source text not null default '';

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
      split_part(v_headers ->> 'x-forwarded-for', ',', 1),
      v_headers ->> 'cf-connecting-ip', ''), 'sha256'), 'hex');
    if (select count(*) from private.error_reports
        where who = '' and first_seen > now() - interval '1 day') >= 100
       or (select count(*) from private.error_reports
           where who = '' and source = v_source
             and first_seen > now() - interval '1 day') >= 10 then
      return;
    end if;
  end if;
  insert into private.error_reports (fingerprint, message, stack, app_version,
                                     platform, who, source)
  values (fp, msg, stk, ver,
          left(coalesce(p_report ->> 'platform', ''), 40), v_who, v_source);
end $$;

-- The new helpers are for these functions only.
revoke all on function private.token_user_any(text) from public, anon, authenticated;
revoke all on function private.token_pages(text) from public, anon, authenticated;
revoke all on function private.table_pages(text) from public, anon, authenticated;
revoke all on function private.may_sync(text[], text) from public, anon, authenticated;
revoke all on function private.remap(jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function private.canonical_ids(jsonb) from public, anon, authenticated;
revoke all on function private.known_user(jsonb) from public, anon, authenticated;

-- ===== migrations/20261121090000_review2_auth.sql =====
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

-- L2: indexes for the change-log columns that are joined on. (No foreign
-- keys: synced rows can arrive before the row they point to.)
create index if not exists count_changes_staff_idx on public.count_changes (staff_id);
create index if not exists revenue_changes_entry_idx on public.revenue_changes (entry_id);
create index if not exists application_changes_import_idx on public.application_changes (import_id);
create index if not exists todo_items_sent_idx on public.todo_items (sent_id);


-- Scheduled company-wide AI summaries (also supplied as a migration).
-- Private, explicitly assigned company-wide daily summaries. No key is returned to apps.
create extension if not exists pg_net with schema extensions;
create table private.ai_summary_config (
 id boolean primary key default true check(id), enabled boolean not null default false,
 model text not null default 'gemini-3.8-flash', key_id uuid, job_key_id uuid not null
);
insert into private.ai_summary_config(job_key_id)
 values(vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'ai_summary_job_token'));
create table private.ai_summary_access (
 user_id bigint primary key references private.app_users(id) on delete cascade
);
create table private.ai_summaries (
 summary_date date primary key, status text not null check(status in ('running','ready','failed')),
 run_id uuid not null, attempts integer not null default 1, lease_until timestamptz not null,
 cutoff_at timestamptz not null, generated_at timestamptz, model text not null,
 content jsonb, input_snapshot jsonb not null, error_code text
);
alter table private.ai_summary_config enable row level security;
alter table private.ai_summary_access enable row level security;
alter table private.ai_summaries enable row level security;
revoke all on private.ai_summary_config, private.ai_summary_access, private.ai_summaries from public,anon,authenticated;

create function public.ai_summary_access(p_token text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if private.token_role(p_token) = 'admin' then return true; end if;
 return exists(select 1 from private.ai_summary_access where user_id=private.token_user(p_token));
end $$;
create function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,
  'today',private.today(),
  'status',coalesce((select status from private.ai_summaries where summary_date=private.today()),'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result
 from private.ai_summary_config c;
 return result;
end $$;
create function public.ai_summary_settings(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 return (select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,'model',c.model,
  'users',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(u.full_name,''),u.username),
  'role',u.role,'assigned',a.user_id is not null) order by u.username)
  from private.app_users u left join private.ai_summary_access a on a.user_id=u.id where u.active),'[]'::jsonb))
  from private.ai_summary_config c);
end $$;
create function public.ai_summary_configure(p_token text,p_enabled boolean,p_model text,p_user_ids bigint[],p_key text default null)
returns void language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config;
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 if p_model is null or p_model !~ '^gemini-[a-zA-Z0-9.-]{1,80}$' then raise exception 'invalid_model'; end if;
 select * into c from private.ai_summary_config for update;
 if nullif(trim(p_key),'') is not null then
  if length(p_key)<20 or length(p_key)>512 then raise exception 'invalid_key'; end if;
  if c.key_id is null then c.key_id:=vault.create_secret(trim(p_key),'ai_summary_gemini_key');
  else perform vault.update_secret(c.key_id,trim(p_key)); end if;
 end if;
 if p_enabled and c.key_id is null then raise exception 'gemini_key_required'; end if;
 update private.ai_summary_config set enabled=p_enabled, model=p_model,key_id=c.key_id where id=true;
 delete from private.ai_summary_access where user_id is not null;
 insert into private.ai_summary_access(user_id) select id from private.app_users
 where active and id=any(coalesce(p_user_ids,'{}'::bigint[]));
end $$;

-- Only aggregate data goes to the model. Personal to-do text, student names,
-- credentials, report descriptions and individual revenue notes are excluded.
create function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' as $$
select jsonb_build_object('date',private.today(),'timezone','Africa/Nairobi','cutoff_at',now(),
 'weekly_tracker',(select jsonb_build_object('today',coalesce(sum(c.new_clients+c.existing_clients) filter(where d.date=private.today()::text),0),
 'month_new',coalesce(sum(c.new_clients),0),'month_existing',coalesce(sum(c.existing_clients),0))
 from public.client_counts c join public.work_days d on d.id=c.day_id
 where d.date>=date_trunc('month',private.today())::date::text and d.date<=private.today()::text
 and not exists(select 1 from public.staff_day_off o where o.day_id=c.day_id and o.staff_id=c.staff_id)),
 'revenue',(select jsonb_build_object('currency',coalesce((select value from public.app_settings where key='currency'),'unspecified'),'today_cents',coalesce(sum(amount_cents) filter(where date=private.today()::text),0),
 'month_net_cents',coalesce(sum(amount_cents),0)) from public.revenue_entries
 where date>=date_trunc('month',private.today())::date::text and date<=private.today()::text),
 'applications',(select jsonb_build_object('total',count(*),'with_offer',count(*) filter(where nullif(offer_date,'') is not null),
 'with_coe',count(*) filter(where nullif(coe_date,'') is not null),'by_status',
 (select coalesce(jsonb_object_agg(status,n),'{}'::jsonb) from (select coalesce(nullif(status,''),'Unspecified') status,count(*) n from public.applications group by 1) x)) from public.applications),
 'daily_reports',(select jsonb_build_object('today',count(*) filter(where report_date=private.today()),
 'open',count(*) filter(where status<>'done' or review='returned'),
 'submitted_today',count(*) filter(where submitted_at>=private.today()::timestamp at time zone 'Africa/Nairobi'),
 'blocked',count(*) filter(where status='blocked'),
 'overdue',count(*) filter(where (status<>'done' or review='returned') and due_date<private.today()),
 'by_status',coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from public.activity_reports where report_date=private.today() group by status) x),'{}'::jsonb))
 from public.activity_reports where report_date<=private.today()),
 'team_todo',(select jsonb_build_object('open',count(*) filter(where not done),'done',count(*) filter(where done)) from public.todo_team_items where not deleted),
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*)) from public.staff),
 'history',(select jsonb_build_object('recorded_weeks',count(*)) from public.weeks),
 'reports','Client performance uses recorded counts; missing entries cannot be assumed to mean no activity.',
 'settings','Summary scheduled at 17:05 Africa/Nairobi. Personal preferences are not included.');
$$;
create function public.ai_summary_claim(p_job_token text,p_run_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; secret text; snapshot jsonb; accepted date;
begin
 select * into c from private.ai_summary_config for update;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null or p_job_token is distinct from secret then raise exception 'invalid_job_token' using errcode='42501'; end if;
 if not c.enabled or c.key_id is null or (now() at time zone 'Africa/Nairobi')::time<'17:00'::time then return null; end if;
 snapshot:=private.ai_summary_context();
 insert into private.ai_summaries(summary_date,status,run_id,lease_until,cutoff_at,model,input_snapshot)
 values(private.today(),'running',p_run_id,now()+interval '4 minutes',now(),c.model,snapshot)
 on conflict(summary_date) do update set status='running',run_id=excluded.run_id,
 attempts=private.ai_summaries.attempts+1,lease_until=excluded.lease_until,cutoff_at=excluded.cutoff_at,
 model=excluded.model,input_snapshot=excluded.input_snapshot,error_code=null
 where private.ai_summaries.status<>'ready' and private.ai_summaries.lease_until<now() and private.ai_summaries.attempts<3
 returning summary_date into accepted;
 if accepted is null then return null; end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.key_id;
 return jsonb_build_object('date',accepted,'model',c.model,'key',secret,'snapshot',snapshot);
end $$;
create function public.ai_summary_finish(p_run_id uuid,p_content jsonb default null,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_content is not null and (jsonb_typeof(p_content)<>'object' or length(p_content::text)>40000) then raise exception 'invalid_summary'; end if;
 update private.ai_summaries set status=case when p_content is null then 'failed' else 'ready' end,
 content=p_content,generated_at=case when p_content is null then null else now() end,
 error_code=case when p_content is null then left(coalesce(p_error,'generation_failed'),80) else null end
 where run_id=p_run_id and status='running' and lease_until>now();
end $$;
create function private.ai_summary_dispatch() returns void
language plpgsql security definer set search_path='' as $$
declare secret text;
begin
 if not exists(select 1 from private.ai_summary_config where enabled and key_id is not null) then return; end if;
 select v.decrypted_secret into secret from private.ai_summary_config c join vault.decrypted_secrets v on v.id=c.job_key_id;
 perform net.http_post(url:='https://dpmluuckgstycdctqwym.supabase.co/functions/v1/daily-ai-summary',
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),body:='{}'::jsonb,timeout_milliseconds:=180000);
end $$;
revoke all on function private.ai_summary_context(),private.ai_summary_dispatch() from public,anon,authenticated;
revoke all on function public.ai_summary_claim(text,uuid),public.ai_summary_finish(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.ai_summary_claim(text,uuid),public.ai_summary_finish(uuid,jsonb,text) to service_role;
revoke all on function public.ai_summary_access(text),public.ai_summary_read(text),public.ai_summary_settings(text),public.ai_summary_configure(text,boolean,text,bigint[],text) from public;
grant execute on function public.ai_summary_access(text),public.ai_summary_read(text),public.ai_summary_settings(text),public.ai_summary_configure(text,boolean,text,bigint[],text) to anon,authenticated;
select cron.schedule('daily-ai-summary','5,15,25 14 * * *','select private.ai_summary_dispatch()');


-- Admin-triggered AI report refreshes.
-- Generation jobs are separate from published reports, so refresh failures never
-- hide or destroy the last successful report. Clients only request jobs via RPC.
create table private.ai_summary_jobs (
 id uuid primary key default gen_random_uuid(), summary_date date not null,
 source text not null check(source in ('manual','scheduled')),
 requested_by bigint references private.app_users(id) on delete set null,
 created_at timestamptz not null default now(), lease_until timestamptz not null,
 status text not null check(status in ('queued','running','ready','failed')),
 run_id uuid unique, cutoff_at timestamptz, model text, input_snapshot jsonb, error_code text
);
create index ai_summary_jobs_date_idx on private.ai_summary_jobs(summary_date,created_at desc);
create index ai_summary_jobs_requested_by_idx on private.ai_summary_jobs(requested_by);
create index ai_summary_jobs_active_idx on private.ai_summary_jobs(lease_until) where status in ('queued','running');
alter table private.ai_summary_jobs enable row level security;
revoke all on private.ai_summary_jobs from public,anon,authenticated;
-- Preserve successful reports produced by the earlier scheduled-only worker.
insert into private.ai_summary_jobs(summary_date,source,created_at,lease_until,status,run_id,cutoff_at,model,input_snapshot)
select summary_date,'scheduled',coalesce(generated_at,cutoff_at),lease_until,'ready',run_id,cutoff_at,model,input_snapshot
from private.ai_summaries where status='ready';


create function public.ai_summary_generate(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; job uuid; secret text;
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 select * into c from private.ai_summary_config for update;
 if c.key_id is null then raise exception 'gemini_key_required'; end if;
 select id into job from private.ai_summary_jobs where status in ('queued','running') and lease_until>now() limit 1;
 if job is not null then return jsonb_build_object('status','running','job_id',job); end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null then raise exception 'job_not_configured'; end if;
 if not exists(select 1 from vault.decrypted_secrets where id=c.key_id) then raise exception 'gemini_key_required'; end if;
 insert into private.ai_summary_jobs(summary_date,source,requested_by,lease_until,status)
 values(private.today(),'manual',private.token_user(p_token),now()+interval '4 minutes','queued') returning id into job;
 perform net.http_post(url:='https://dpmluuckgstycdctqwym.supabase.co/functions/v1/daily-ai-summary',
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),
 body:=jsonb_build_object('manual_job_id',job),timeout_milliseconds:=180000);
 return jsonb_build_object('status','queued','job_id',job);
end $$;

create function public.ai_summary_claim_job(p_job_token text,p_run_id uuid,p_manual_job uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; secret text; api_key text; job private.ai_summary_jobs; snapshot jsonb;
begin
 select * into c from private.ai_summary_config for update;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null or p_job_token is distinct from secret then raise exception 'invalid_job_token' using errcode='42501'; end if;
 if c.key_id is null then return null; end if;
 select decrypted_secret into api_key from vault.decrypted_secrets where id=c.key_id;
 if api_key is null then return null; end if;
 if p_manual_job is null then
  if not c.enabled or (now() at time zone 'Africa/Nairobi')::time<'17:00'::time then return null; end if;
  if exists(select 1 from private.ai_summary_jobs where status in ('queued','running') and lease_until>now()) then return null; end if;
  -- Manual refreshes never cancel the regular evening report.
  if exists(select 1 from private.ai_summary_jobs where summary_date=private.today()
    and source='scheduled' and status='ready') then return null; end if;
  if (select count(*) from private.ai_summary_jobs where summary_date=private.today() and source='scheduled')>=3 then return null; end if;
  insert into private.ai_summary_jobs(summary_date,source,lease_until,status,run_id)
  values(private.today(),'scheduled',now()+interval '4 minutes','running',p_run_id) returning * into job;
 else
  select * into job from private.ai_summary_jobs where id=p_manual_job for update;
  if job.id is null or job.source<>'manual' or job.status<>'queued' or job.lease_until<=now() then return null; end if;
  -- Recheck the requesting account at execution time.
  if not exists(select 1 from private.app_users where id=job.requested_by and active and role='admin') then
   update private.ai_summary_jobs set status='failed',error_code='admin_required' where id=job.id;
   return null;
  end if;
  if exists(select 1 from private.ai_summary_jobs where id<>job.id and status='running' and lease_until>now()) then return null; end if;
  update private.ai_summary_jobs set status='running',summary_date=private.today(),run_id=p_run_id,lease_until=now()+interval '4 minutes' where id=job.id;
  job.summary_date:=private.today();
 end if;
 snapshot:=private.ai_summary_context();
 update private.ai_summary_jobs set model=c.model,input_snapshot=snapshot,cutoff_at=now() where id=job.id;
 return jsonb_build_object('date',job.summary_date,'model',c.model,'key',api_key,'snapshot',snapshot);
end $$;
-- Keep the scheduler RPC compatible with existing worker deployments.
create or replace function public.ai_summary_claim(p_job_token text,p_run_id uuid) returns jsonb
language sql security definer set search_path='' as $$
 select public.ai_summary_claim_job(p_job_token,p_run_id,null);
$$;
create or replace function public.ai_summary_finish(p_run_id uuid,p_content jsonb default null,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job private.ai_summary_jobs;
begin
 if p_content is not null and (jsonb_typeof(p_content)<>'object' or length(p_content::text)>40000) then raise exception 'invalid_summary'; end if;
 select * into job from private.ai_summary_jobs where run_id=p_run_id and status='running' and lease_until>now() for update;
 if job.id is null then return; end if;
 update private.ai_summary_jobs set status=case when p_content is null then 'failed' else 'ready' end,
 error_code=case when p_content is null then left(coalesce(p_error,'generation_failed'),80) else null end where id=job.id;
 if p_content is null then return; end if;
 insert into private.ai_summaries(summary_date,status,run_id,attempts,lease_until,cutoff_at,generated_at,model,content,input_snapshot,error_code)
 values(job.summary_date,'ready',p_run_id,1,job.lease_until,job.cutoff_at,now(),job.model,p_content,job.input_snapshot,null)
 on conflict(summary_date) do update set status='ready',run_id=excluded.run_id,attempts=1,
 lease_until=excluded.lease_until,cutoff_at=excluded.cutoff_at,generated_at=excluded.generated_at,
 model=excluded.model,content=excluded.content,input_snapshot=excluded.input_snapshot,error_code=null
 where private.ai_summaries.cutoff_at<=excluded.cutoff_at;
end $$;
create or replace function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; job private.ai_summary_jobs; state text;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select * into job from private.ai_summary_jobs where summary_date=private.today()
  or (status in ('queued','running') and lease_until>now())
 order by (status in ('queued','running') and lease_until>now()) desc,created_at desc,id desc limit 1;
 state:=case when job.status in ('queued','running') and job.lease_until<=now() then 'failed' else job.status end;
 if state is null then select status into state from private.ai_summaries where summary_date=private.today(); end if;
 select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,
  'can_generate',private.token_role(p_token)='admin','today',private.today(),'status',coalesce(state,'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;
revoke all on function public.ai_summary_generate(text) from public;
grant execute on function public.ai_summary_generate(text) to anon,authenticated;
revoke all on function public.ai_summary_claim_job(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.ai_summary_claim_job(text,uuid,uuid) to service_role;


-- Verified model and actionable report failures.
-- Use the lightweight model verified with this project's key. Other explicit model choices are kept.
alter table private.ai_summary_config alter column model set default 'gemini-3.5-flash-lite';
update private.ai_summary_config set model='gemini-3.5-flash-lite' where id=true and model='gemini-3.8-flash';
-- Return safe, actionable failure text; never return raw provider errors or credentials.
create or replace function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; job private.ai_summary_jobs; state text; failure text;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select * into job from private.ai_summary_jobs where summary_date=private.today()
  or (status in ('queued','running') and lease_until>now())
 order by (status in ('queued','running') and lease_until>now()) desc,created_at desc,id desc limit 1;
 state:=case when job.status in ('queued','running') and job.lease_until<=now() then 'failed' else job.status end;
 if state is null then select status into state from private.ai_summaries where summary_date=private.today(); end if;
 failure:=case
  when job.error_code in ('gemini_http_503','gemini_http_500','gemini_http_502','gemini_http_504','gemini_temporarily_unavailable') then 'Gemini is temporarily busy. Please try generating the report again shortly.'
  when job.error_code in ('gemini_http_429','gemini_quota_exceeded') then 'Gemini quota or rate limit reached. Check your Google AI Studio usage and try again later.'
  when job.error_code in ('gemini_http_401','gemini_http_403','gemini_key_rejected') then 'Gemini rejected access. Admin should check the API key and its project permissions in Settings.'
  when job.error_code in ('gemini_http_404','gemini_model_unavailable') then 'The selected Gemini model is unavailable for this key. Admin can choose an available model in Settings.'
  when job.error_code='gemini_timeout' or (job.status in ('queued','running') and job.lease_until<=now()) then 'The report request timed out. Please try generating it again.'
  when job.error_code='gemini_request_invalid' then 'Gemini could not accept the report request. Check the selected model or contact Admin.'
  when job.error_code in ('gemini_incomplete','gemini_invalid_report') then 'Gemini returned an incomplete report. Please try generating it again.'
  else 'The report could not be generated. Please try again or contact Admin.' end;
 select jsonb_build_object('error_message',case when state='failed' then failure else null end,'enabled',c.enabled,'configured',c.key_id is not null,
  'can_generate',private.token_role(p_token)='admin','today',private.today(),'status',coalesce(state,'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;


-- Business-facing detail and explicit revenue amounts.
-- Explicit money units and client counts for readable, detailed reports.
create or replace function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' as $$
select jsonb_build_object('date',private.today(),'timezone','Africa/Nairobi','cutoff_at',now(),
 'weekly_tracker',(select jsonb_build_object('today',coalesce(sum(c.new_clients+c.existing_clients) filter(where d.date=private.today()::text),0),
 'today_new',coalesce(sum(c.new_clients) filter(where d.date=private.today()::text),0),
 'today_existing',coalesce(sum(c.existing_clients) filter(where d.date=private.today()::text),0),
 'month_total',coalesce(sum(c.new_clients+c.existing_clients),0),
 'month_new',coalesce(sum(c.new_clients),0),'month_existing',coalesce(sum(c.existing_clients),0))
 from public.client_counts c join public.work_days d on d.id=c.day_id
 where d.date>=date_trunc('month',private.today())::date::text and d.date<=private.today()::text
 and not exists(select 1 from public.staff_day_off o where o.day_id=c.day_id and o.staff_id=c.staff_id)),
 'revenue',(select jsonb_build_object('currency',coalesce(nullif(trim((select value from public.app_settings where key='currency')),''),'KSh'),'today_cents',coalesce(sum(amount_cents) filter(where date=private.today()::text),0),
 'month_net_cents',coalesce(sum(amount_cents),0),
 'today_amount',coalesce(sum(amount_cents) filter(where date=private.today()::text),0)/100.0,
 'month_net_amount',coalesce(sum(amount_cents),0)/100.0,
 'amount_note','Amounts are currency units. The *_cents fields are storage hundredths, not whole currency.') from public.revenue_entries
 where date>=date_trunc('month',private.today())::date::text and date<=private.today()::text),
 'applications',(select jsonb_build_object('total',count(*),'with_offer',count(*) filter(where nullif(offer_date,'') is not null),
 'with_coe',count(*) filter(where nullif(coe_date,'') is not null),'by_status',
 (select coalesce(jsonb_object_agg(status,n),'{}'::jsonb) from (select coalesce(nullif(status,''),'Unspecified') status,count(*) n from public.applications group by 1) x)) from public.applications),
 'daily_reports',(select jsonb_build_object('today',count(*) filter(where report_date=private.today()),
 'open',count(*) filter(where status<>'done' or review='returned'),
 'submitted_today',count(*) filter(where submitted_at>=private.today()::timestamp at time zone 'Africa/Nairobi'),
 'blocked',count(*) filter(where status='blocked'),
 'overdue',count(*) filter(where (status<>'done' or review='returned') and due_date<private.today()),
 'by_status',coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from public.activity_reports where report_date=private.today() group by status) x),'{}'::jsonb))
 from public.activity_reports where report_date<=private.today()),
 'team_todo',(select jsonb_build_object('open',count(*) filter(where not done),'done',count(*) filter(where done)) from public.todo_team_items where not deleted),
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*)) from public.staff),
 'history',(select jsonb_build_object('recorded_weeks',count(*)) from public.weeks),
 'reports','Client performance uses recorded counts; missing entries cannot be assumed to mean no activity.',
 'settings',(select jsonb_build_object('schedule_enabled',enabled,'scheduled_time','17:05','timezone','Africa/Nairobi') from private.ai_summary_config));
$$;

create or replace function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' set timezone='Africa/Nairobi' as $$
-- Legacy timestamps without an offset were recorded in Nairobi local time.
with changes_today as (
  select app_key, field, old_value, new_value
  from public.application_changes
  where case when pg_input_is_valid(changed_at, 'timestamp with time zone') then
    changed_at::timestamptz >= private.today()::timestamp at time zone 'Africa/Nairobi'
    and changed_at::timestamptz <= now()
  else false end
), application_updates as (
  select jsonb_build_object(
    'applications_touched', count(distinct app_key),
    'added', count(distinct app_key) filter (where field = 'added'),
    'removed', count(distinct app_key) filter (where field = 'removed'),
    'statuses_changed', count(distinct app_key) filter (where field = 'status'),
    'documents_updated', count(distinct app_key) filter (where field = 'doc_date'),
    'submission_dates_updated', count(distinct app_key) filter (where field = 'app_date'),
    'offers_logged', count(distinct app_key) filter (
      where field = 'offer_date' and trim(old_value) = '' and trim(new_value) <> ''
    ),
    'coes_logged', count(distinct app_key) filter (
      where field = 'coe_date' and trim(old_value) = '' and trim(new_value) <> ''
    ),
    'offer_or_coe_dates_corrected', count(distinct app_key) filter (
      where field in ('offer_date', 'coe_date') and trim(old_value) <> ''
    ),
    'follow_ups_updated', count(distinct app_key) filter (where field in ('todo', 'follow_up'))
  ) as counts
  from changes_today
)
select jsonb_build_object('date',private.today(),'timezone','Africa/Nairobi','cutoff_at',now(),
 'weekly_tracker',(select jsonb_build_object('today',coalesce(sum(c.new_clients+c.existing_clients) filter(where d.date=private.today()::text),0),
 'today_new',coalesce(sum(c.new_clients) filter(where d.date=private.today()::text),0),
 'today_existing',coalesce(sum(c.existing_clients) filter(where d.date=private.today()::text),0),
 'month_total',coalesce(sum(c.new_clients+c.existing_clients),0),
 'month_new',coalesce(sum(c.new_clients),0),'month_existing',coalesce(sum(c.existing_clients),0))
 from public.client_counts c join public.work_days d on d.id=c.day_id
 where d.date>=date_trunc('month',private.today())::date::text and d.date<=private.today()::text
 and not exists(select 1 from public.staff_day_off o where o.day_id=c.day_id and o.staff_id=c.staff_id)),
 'revenue',(select jsonb_build_object('currency',coalesce(nullif(trim((select value from public.app_settings where key='currency')),''),'KSh'),'today_cents',coalesce(sum(amount_cents) filter(where date=private.today()::text),0),
 'month_net_cents',coalesce(sum(amount_cents),0),
 'today_amount',coalesce(sum(amount_cents) filter(where date=private.today()::text),0)/100.0,
 'month_net_amount',coalesce(sum(amount_cents),0)/100.0,
 'amount_note','Amounts are currency units. The *_cents fields are storage hundredths, not whole currency.') from public.revenue_entries
 where date>=date_trunc('month',private.today())::date::text and date<=private.today()::text),
 'applications',(select jsonb_build_object('updates_today',(select counts from application_updates),'total',count(*),'with_offer',count(*) filter(where nullif(offer_date,'') is not null),
 'with_coe',count(*) filter(where nullif(coe_date,'') is not null),'by_status',
 (select coalesce(jsonb_object_agg(status,n),'{}'::jsonb) from (select coalesce(nullif(status,''),'Unspecified') status,count(*) n from public.applications group by 1) x)) from public.applications),
 'daily_reports',(select jsonb_build_object('today',count(*) filter(where report_date=private.today()),
 'open',count(*) filter(where status<>'done' or review='returned'),
 'submitted_today',count(*) filter(where submitted_at>=private.today()::timestamp at time zone 'Africa/Nairobi'),
 'blocked',count(*) filter(where status='blocked'),
 'overdue',count(*) filter(where (status<>'done' or review='returned') and due_date<private.today()),
 'by_status',coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from public.activity_reports where report_date=private.today() group by status) x),'{}'::jsonb))
 from public.activity_reports where report_date<=private.today()),
 'team_todo',(select jsonb_build_object('open',count(*) filter(where not done),'done',count(*) filter(where done)) from public.todo_team_items where not deleted),
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*)) from public.staff));
$$;
