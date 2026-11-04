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
