-- ===== Daily reports for the team (2026-11-09) =====
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
