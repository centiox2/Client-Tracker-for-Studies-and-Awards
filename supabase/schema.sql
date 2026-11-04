-- Client Tracker: online database setup for Supabase.
-- Run this once in a new Supabase project (SQL Editor → New query → paste → Run).
-- It is the same setup as the original project, in the order it was applied.

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
