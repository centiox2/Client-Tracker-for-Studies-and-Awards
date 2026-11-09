-- ===== Daily activity reports (2026-11-09) =====
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
