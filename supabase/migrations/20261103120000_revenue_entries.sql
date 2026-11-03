-- Revenue: one row per transaction, mirroring the app's SQLite table
-- (app schema v8). Additive: older app builds ignore it.

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
