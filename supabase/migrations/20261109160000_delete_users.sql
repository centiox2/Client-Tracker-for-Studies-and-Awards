-- ===== Deleting accounts (2026-11-09) =====
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
