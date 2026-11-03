-- App schema v9: payment purpose, refunds, revenue change history; and a
-- one-time recovery code for a forgotten online admin password.
-- Additive: older app builds ignore the new column/table.

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
