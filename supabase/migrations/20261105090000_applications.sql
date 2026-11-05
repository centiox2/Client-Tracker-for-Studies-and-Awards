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
