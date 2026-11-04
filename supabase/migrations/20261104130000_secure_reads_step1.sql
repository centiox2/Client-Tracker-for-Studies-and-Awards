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
