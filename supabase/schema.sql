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
