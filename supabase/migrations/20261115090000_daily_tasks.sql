-- Daily reports become tasks.
--
-- Every entry is now a task that belongs to one person. It can be on their
-- to-do list (to_do / in_progress / blocked) or done. When done it is
-- submitted for the day it was submitted on (report_date is set by the server,
-- never picked by the user), and a reviewer approves it or returns it with a
-- comment. Directors, managers and department heads can assign tasks to anyone,
-- with an urgency colour. People are notified about the things that need them.
--
-- The old rows are dropped on purpose: the business agreed the old daily
-- report data does not need to be kept.

truncate public.report_comments, public.activity_changes, public.activity_reports
  restart identity;

drop index if exists public.activity_reports_open_idx;

alter table public.activity_reports
  drop constraint if exists activity_reports_status_check,
  drop constraint if exists activity_reports_priority_check,
  drop constraint if exists activity_reports_next_action_check,
  drop column if exists next_action,
  drop column if exists priority;

alter table public.activity_reports
  alter column report_date drop not null,
  alter column report_date drop default,
  alter column status set default 'to_do',
  add column if not exists details text not null default ''
    check (length(details) <= 4000),
  add column if not exists urgency text not null default 'normal'
    check (urgency in ('low', 'normal', 'high', 'urgent')),
  add column if not exists review text not null default 'none'
    check (review in ('none', 'submitted', 'approved', 'returned')),
  add column if not exists submitted_at timestamptz,
  add column if not exists reviewed_by bigint
    references private.app_users(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add constraint activity_reports_status_check
    check (status in ('to_do', 'in_progress', 'blocked', 'done'));

create index if not exists activity_reports_open_idx
  on public.activity_reports (user_id) where status <> 'done';
create index if not exists activity_reports_review_idx
  on public.activity_reports (review) where review = 'submitted';
create index if not exists activity_reports_assigned_idx
  on public.activity_reports (assigned_by) where assigned_by is not null;

alter table public.activity_changes
  drop constraint if exists activity_changes_action_check,
  add constraint activity_changes_action_check
    check (action in ('created', 'edited', 'deleted', 'submitted',
                      'approved', 'returned'));

-- Comments double as the review timeline.
alter table public.report_comments
  drop constraint if exists report_comments_body_check,
  add column if not exists kind text not null default 'comment'
    check (kind in ('comment', 'submitted', 'approved', 'returned'));
alter table public.report_comments
  add constraint report_comments_body_check
    check (length(body) <= 1000 and (kind <> 'comment' or length(trim(body)) > 0));

-- Notifications ----------------------------------------------------------
create table if not exists public.report_notifications (
  id bigint generated always as identity primary key,
  user_id bigint not null references private.app_users(id) on delete cascade,
  kind text not null check (kind in ('assigned', 'submitted', 'approved',
    'returned', 'comment', 'blocked', 'due_today', 'overdue', 'reminder',
    'reassigned')),
  report_id bigint references public.activity_reports(id) on delete cascade,
  actor_id bigint references private.app_users(id) on delete set null,
  body text not null default '',
  dedupe text unique,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists report_notifications_user_idx
  on public.report_notifications (user_id, id desc);
alter table public.report_notifications enable row level security;
revoke all on public.report_notifications from anon, authenticated;

create or replace function private.notify(p_user bigint, p_kind text,
    p_report bigint, p_actor bigint, p_body text default '',
    p_dedupe text default null)
returns void
language sql
security definer
set search_path to ''
as $$
  insert into public.report_notifications (user_id, kind, report_id, actor_id, body, dedupe)
  select p_user, p_kind, p_report, p_actor, left(coalesce(p_body, ''), 300), p_dedupe
  where p_user is not null and p_user is distinct from p_actor
    and exists (select 1 from private.app_users where id = p_user and active)
  on conflict (dedupe) do nothing;
$$;

-- Access -----------------------------------------------------------------
-- Who can see a task: the owner, whoever assigned it, and the people whose
-- report scope covers the owner.
create or replace function private.can_see_task(p_user bigint, r public.activity_reports)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(r.user_id = p_user or r.assigned_by is not distinct from p_user
      or private.can_see_report(p_user, r.user_id, r.department_id), false);
$$;

-- Who can review: never the owner. The person who assigned it, anyone with
-- company-wide scope, or the head of the task's department.
create or replace function private.can_review(p_user bigint, r public.activity_reports)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(r.user_id <> p_user and (
    r.assigned_by is not distinct from p_user
    or private.report_scope(p_user) = 'all'
    or (private.report_scope(p_user) = 'department'
        and r.department_id is not distinct from
            (select department_id from private.app_users where id = p_user))), false);
$$;

create or replace function private.can_assign(p_user bigint)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(private.report_scope(p_user) <> 'own', false);
$$;

create or replace function private.report_json(r public.activity_reports)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select to_jsonb(r) || jsonb_build_object(
    'user_name', (select full_name from private.app_users where id = r.user_id),
    'department_name', (select name from public.departments where id = r.department_id),
    'assigned_by_name', (select full_name from private.app_users where id = r.assigned_by),
    'reviewed_by_name', (select full_name from private.app_users where id = r.reviewed_by),
    'comment_count', (select count(*) from public.report_comments c
                      where c.report_id = r.id and c.kind = 'comment'),
    'last_review_note', (select c.body from public.report_comments c
                         where c.report_id = r.id and c.kind in ('approved', 'returned')
                         order by c.id desc limit 1));
$$;

-- Meta -------------------------------------------------------------------
create or replace function public.reports_meta(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  scope text := private.report_scope(me);
  my_dept bigint := (select department_id from private.app_users where id = me);
begin
  return jsonb_build_object(
    'today', private.today(),
    'now', private.kenya_now_text(),
    'me', private.user_json(me) || jsonb_build_object(
      'scope', scope, 'can_assign', private.can_assign(me)),
    'departments', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.position, d.name)
      from public.departments d), '[]'::jsonb),
    -- People a manager can filter by, and assign to. Anyone who can assign
    -- can assign to anyone active.
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'full_name', u.full_name,
               'department_id', u.department_id, 'active', u.active)
             order by lower(u.full_name))
      from private.app_users u
      where scope <> 'own' or u.id = me), '[]'::jsonb)
  );
end $$;

-- List -------------------------------------------------------------------
create or replace function public.report_list(p_token text, p_filter jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_from date := nullif(f->>'from', '')::date;
  v_to date := nullif(f->>'to', '')::date;
  v_dept bigint := nullif(f->>'department_id', '')::bigint;
  v_user bigint := nullif(f->>'user_id', '')::bigint;
  v_statuses text[] := case when jsonb_typeof(f->'statuses') = 'array'
    then array(select jsonb_array_elements_text(f->'statuses')) end;
  v_reviews text[] := case when jsonb_typeof(f->'reviews') = 'array'
    then array(select jsonb_array_elements_text(f->'reviews')) end;
  v_urgency text := nullif(f->>'urgency', '');
  v_open boolean := coalesce((f->>'open_only')::boolean, false);
  v_overdue boolean := coalesce((f->>'overdue_only')::boolean, false);
  v_assigned_by_me boolean := coalesce((f->>'assigned_by_me')::boolean, false);
  v_to_review boolean := coalesce((f->>'to_review')::boolean, false);
  v_reviewed_by_me boolean := coalesce((f->>'reviewed_by_me')::boolean, false);
  v_search text := nullif(trim(coalesce(f->>'search', '')), '');
  v_id bigint := case when v_search ~ '^#?[0-9]{1,12}$'
    then ltrim(v_search, '#')::bigint end;
  v_limit int := least(greatest(coalesce((f->>'limit')::int, 500), 1), 3000);
begin
  return coalesce((
    select jsonb_agg(private.report_json(r) order by
        coalesce(r.submitted_at, r.updated_at) desc, r.id desc)
    from (
      select * from public.activity_reports r
      where private.can_see_task(me, r)
        and (v_from is null or r.report_date >= v_from)
        and (v_to is null or r.report_date <= v_to)
        and (v_dept is null or r.department_id = v_dept)
        and (v_user is null or r.user_id = v_user)
        and (v_statuses is null or r.status = any(v_statuses))
        and (v_reviews is null or r.review = any(v_reviews))
        and (v_urgency is null or r.urgency = v_urgency)
        and (not v_open or r.status <> 'done' or r.review = 'returned')
        and (not v_overdue or (r.status <> 'done' and r.due_date < private.today()))
        and (not v_assigned_by_me or r.assigned_by is not distinct from me)
        and (not v_to_review or (r.review = 'submitted' and private.can_review(me, r)))
        and (not v_reviewed_by_me or r.reviewed_by is not distinct from me)
        and (v_search is null or r.id = v_id or private.search_hit(v_search,
              concat_ws(' ', r.description, r.details, r.reference, r.blocker,
                (select full_name from private.app_users where id = r.user_id),
                (select full_name from private.app_users where id = r.assigned_by),
                (select name from public.departments where id = r.department_id))))
      order by coalesce(r.submitted_at, r.updated_at) desc, r.id desc
      limit v_limit
    ) r), '[]'::jsonb);
end $$;

-- Save -------------------------------------------------------------------
-- p_report: id?, user_id? (assign to), description (title), details,
-- reference, outputs, status, urgency, due_date, blocker, submit (bool).
create or replace function public.report_save(p_token text, p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  u private.app_users;
  owner private.app_users;
  rid bigint := nullif(p_report->>'id', '')::bigint;
  v_for bigint := nullif(p_report->>'user_id', '')::bigint;
  before public.activity_reports;
  saved public.activity_reports;
  v_status text := coalesce(nullif(p_report->>'status', ''), 'to_do');
  v_urgency text := coalesce(nullif(p_report->>'urgency', ''), 'normal');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_submit boolean := coalesce((p_report->>'submit')::boolean, false);
  v_title text := trim(coalesce(p_report->>'description', ''));
  v_dept bigint;
  v_assigned bigint;
  v_owner bigint;
  v_review text;
  v_report_date date;
  v_submitted timestamptz;
begin
  select * into u from private.app_users where id = me;
  if v_status not in ('to_do', 'in_progress', 'blocked', 'done') then
    raise exception 'bad_status' using errcode = '22023';
  end if;
  if v_urgency not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'bad_urgency' using errcode = '22023';
  end if;
  if length(v_title) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  if v_submit then v_status := 'done'; end if;

  if rid is not null then
    select * into before from public.activity_reports where id = rid for update;
    if before.id is null then
      raise exception 'unknown_report' using errcode = '22023';
    end if;
    if not (before.user_id = me or before.assigned_by is not distinct from me or u.role = 'admin') then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    -- The owner can't change work once it is waiting for review or approved.
    if before.review in ('submitted', 'approved') and before.user_id = me
       and before.assigned_by is distinct from me and u.role is distinct from 'admin' then
      raise exception 'already_submitted' using errcode = '42501';
    end if;
    v_owner := before.user_id;
    v_assigned := before.assigned_by;
    -- Whoever assigned the task can hand it to someone else.
    if v_for is not null and v_for <> before.user_id
       and (before.assigned_by is not distinct from me or u.role = 'admin') then
      select * into owner from private.app_users where id = v_for and active;
      if owner.id is null then
        raise exception 'unknown_user' using errcode = '22023';
      end if;
      v_owner := owner.id;
    end if;
    v_dept := case when v_owner = before.user_id then before.department_id
                   else owner.department_id end;
  elsif v_for is not null and v_for <> me then
    if not private.can_assign(me) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    select * into owner from private.app_users where id = v_for and active;
    if owner.id is null then
      raise exception 'unknown_user' using errcode = '22023';
    end if;
    v_owner := owner.id;
    v_dept := owner.department_id;
    v_assigned := me;
    v_submit := false;
    if v_status = 'done' then v_status := 'to_do'; end if;
  else
    v_owner := me;
    v_dept := u.department_id;
  end if;

  if v_status = 'blocked' and length(trim(coalesce(p_report->>'blocker', ''))) = 0 then
    raise exception 'blocker_required' using errcode = '22023';
  end if;

  v_review := coalesce(before.review, 'none');
  v_report_date := before.report_date;
  v_submitted := before.submitted_at;
  if v_submit then
    if v_owner <> me then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_review := 'submitted';
    v_report_date := private.today();
    v_submitted := now();
  elsif v_status <> 'done' and v_review = 'approved' then
    v_review := 'none';
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date,
        description, details, reference, outputs, status, blocker, urgency,
        due_date, assigned_by, review, submitted_at)
      values (v_owner, v_dept, v_report_date, left(v_title, 2000),
        left(trim(coalesce(p_report->>'details', '')), 4000),
        left(trim(coalesce(p_report->>'reference', '')), 200),
        private.clean_outputs(p_report->'outputs', v_dept),
        v_status, left(trim(coalesce(p_report->>'blocker', '')), 1000), v_urgency,
        v_due, v_assigned, v_review, v_submitted)
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, after)
      values (saved.id, me, 'created', to_jsonb(saved));
    if v_assigned is not null then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
    end if;
  else
    update public.activity_reports set
        user_id = v_owner,
        department_id = v_dept,
        report_date = v_report_date,
        description = left(v_title, 2000),
        details = left(trim(coalesce(p_report->>'details', '')), 4000),
        reference = left(trim(coalesce(p_report->>'reference', '')), 200),
        outputs = private.clean_outputs(p_report->'outputs', v_dept, before.outputs),
        status = v_status,
        blocker = case when v_status = 'blocked'
                       then left(trim(coalesce(p_report->>'blocker', '')), 1000) else '' end,
        urgency = v_urgency,
        due_date = v_due,
        review = v_review,
        submitted_at = v_submitted,
        updated_at = now()
      where id = rid
      returning * into saved;
    insert into public.activity_changes (report_id, changed_by, action, before, after)
      values (rid, me, case when v_submit then 'submitted' else 'edited' end,
              to_jsonb(before), to_jsonb(saved));
    if saved.user_id <> before.user_id then
      perform private.notify(saved.user_id, 'assigned', saved.id, me, saved.description);
      perform private.notify(before.user_id, 'reassigned', saved.id, me, saved.description);
    elsif before.assigned_by is not distinct from me and saved.user_id <> me
          and (saved.urgency <> before.urgency or saved.due_date is distinct from before.due_date
               or saved.description <> before.description) then
      perform private.notify(saved.user_id, 'assigned', saved.id, me,
        'Updated: ' || saved.description);
    end if;
    if saved.status = 'blocked' and before.status <> 'blocked' then
      perform private.notify(saved.assigned_by, 'blocked', saved.id, me, saved.blocker);
    end if;
  end if;

  if v_submit then
    insert into public.report_comments (report_id, user_id, kind, body)
      values (saved.id, me, 'submitted', left(trim(coalesce(p_report->>'note', '')), 1000));
    perform private.notify(saved.assigned_by, 'submitted', saved.id, me, saved.description);
  end if;
  return private.report_json(saved);
end $$;

-- Review -----------------------------------------------------------------
create or replace function public.report_review(p_token text, p_report bigint,
    p_decision text, p_comment text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  saved public.activity_reports;
  v_note text := left(trim(coalesce(p_comment, '')), 1000);
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_review(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'returned') then
    raise exception 'bad_decision' using errcode = '22023';
  end if;
  if r.review <> 'submitted' and not (r.review in ('approved', 'returned')
                                      and r.reviewed_by is not distinct from me) then
    raise exception 'not_submitted' using errcode = '22023';
  end if;
  if p_decision = 'returned' and length(v_note) = 0 then
    raise exception 'comment_required' using errcode = '22023';
  end if;
  update public.activity_reports set
      review = p_decision,
      status = case when p_decision = 'returned' then 'in_progress' else 'done' end,
      reviewed_by = me, reviewed_at = now(), updated_at = now()
    where id = p_report
    returning * into saved;
  insert into public.report_comments (report_id, user_id, kind, body)
    values (p_report, me, p_decision, v_note);
  insert into public.activity_changes (report_id, changed_by, action, before, after)
    values (p_report, me, p_decision, to_jsonb(r), to_jsonb(saved));
  perform private.notify(saved.user_id, p_decision, saved.id, me,
    case when v_note = '' then saved.description else v_note end);
  return private.report_json(saved);
end $$;

-- Delete -----------------------------------------------------------------
create or replace function public.report_delete(p_token text, p_report bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  v_role text := (select role from private.app_users where id = me);
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then return; end if;
  if not (r.assigned_by is not distinct from me or v_role = 'admin'
          or (r.user_id = me and r.assigned_by is null and r.review <> 'approved')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.activity_reports where id = p_report;
  insert into public.activity_changes (report_id, changed_by, action, before)
    values (p_report, me, 'deleted', to_jsonb(r));
end $$;

-- Comments / timeline ----------------------------------------------------
create or replace function public.report_comments(p_token text, p_report bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null or not private.can_see_task(me, r) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'body', c.body, 'kind', c.kind, 'created_at', c.created_at,
      'user_id', c.user_id,
      'user_name', (select full_name from private.app_users where id = c.user_id))
      order by c.id)
    from public.report_comments c where c.report_id = p_report), '[]'::jsonb);
end $$;

create or replace function public.report_comment_add(p_token text, p_report bigint, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  v_body text := left(trim(coalesce(p_body, '')), 1000);
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if not private.can_see_task(me, r) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if length(v_body) = 0 then
    raise exception 'description_required' using errcode = '22023';
  end if;
  insert into public.report_comments (report_id, user_id, body) values (p_report, me, v_body);
  perform private.notify(r.user_id, 'comment', r.id, me, v_body);
  if r.assigned_by is distinct from r.user_id then
    perform private.notify(r.assigned_by, 'comment', r.id, me, v_body);
  end if;
  if r.reviewed_by is distinct from r.user_id and r.reviewed_by is distinct from r.assigned_by then
    perform private.notify(r.reviewed_by, 'comment', r.id, me, v_body);
  end if;
  return public.report_comments(p_token, p_report);
end $$;

create or replace function public.report_comment_delete(p_token text, p_comment bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  delete from public.report_comments c
  where c.id = p_comment and c.kind = 'comment'
    and (c.user_id = me or (select role from private.app_users where id = me) = 'admin');
end $$;

create or replace function public.report_history(p_token text, p_report bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report;
  if r.id is null then
    select (jsonb_populate_record(null::public.activity_reports, c.before)).* into r
      from public.activity_changes c
      where c.report_id = p_report and c.action = 'deleted'
      order by c.id desc limit 1;
  end if;
  if r.id is null or not private.can_see_task(me, r) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', c.action, 'changed_at', c.changed_at,
      'changed_by', (select full_name from private.app_users where id = c.changed_by),
      'before', c.before, 'after', c.after) order by c.id)
    from public.activity_changes c where c.report_id = p_report), '[]'::jsonb);
end $$;

-- Notifications ----------------------------------------------------------
-- Makes the once-a-day reminders, then returns the counts the app shows as
-- badges. Cheap enough to poll every minute.
create or replace function private.make_reminders(p_user bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := private.today();
  v_now timestamp := now() at time zone 'Africa/Nairobi';
  r record;
begin
  for r in select id, description, due_date from public.activity_reports
           where user_id = p_user and status <> 'done' and due_date <= v_today
  loop
    if r.due_date = v_today then
      perform private.notify(p_user, 'due_today', r.id, null, r.description,
        'due:' || r.id || ':' || v_today);
    else
      perform private.notify(p_user, 'overdue', r.id, null, r.description,
        'over:' || r.id || ':' || p_user);
    end if;
  end loop;
  -- Assigners hear once when something they handed out goes overdue.
  for r in select id, description, assigned_by from public.activity_reports
           where assigned_by = p_user and user_id <> p_user and status <> 'done'
             and due_date < v_today
  loop
    perform private.notify(p_user, 'overdue', r.id, null, r.description,
      'late:' || r.id || ':' || p_user);
  end loop;
  -- A nudge late on a working day when nothing was submitted.
  if extract(isodow from v_today) < 6 and extract(hour from v_now) >= 16
     and (select department_id from private.app_users where id = p_user) is not null
     and not exists (select 1 from public.activity_reports
                     where user_id = p_user and report_date = v_today) then
    perform private.notify(p_user, 'reminder', null, null,
      'You haven''t submitted anything for today yet.',
      'remind:' || p_user || ':' || v_today);
  end if;
end $$;

create or replace function public.report_badge(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  perform private.make_reminders(me);
  return jsonb_build_object(
    'unread', (select count(*) from public.report_notifications
               where user_id = me and read_at is null),
    'to_review', (select count(*) from public.activity_reports r
                  where r.review = 'submitted' and private.can_review(me, r)),
    'submitted_today', exists (select 1 from public.activity_reports
                               where user_id = me and report_date = private.today()),
    'needs_report', (select department_id from private.app_users where id = me) is not null);
end $$;

create or replace function public.report_notifications(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'report_id', n.report_id, 'body', n.body,
      'created_at', n.created_at, 'read', n.read_at is not null,
      'actor_name', (select full_name from private.app_users where id = n.actor_id),
      'task', (select description from public.activity_reports where id = n.report_id),
      'urgency', (select urgency from public.activity_reports where id = n.report_id))
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n), '[]'::jsonb);
end $$;

create or replace function public.report_notifications_read(p_token text, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  update public.report_notifications set read_at = now()
    where user_id = me and read_at is null
      and (p_ids is null or id = any(p_ids));
  delete from public.report_notifications
    where user_id = me and created_at < now() - interval '60 days';
end $$;

-- Start ------------------------------------------------------------------
-- Everything the page needs on open, in one round trip.
create or replace function public.report_start(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return jsonb_build_object(
    'meta', public.reports_meta(p_token),
    'badge', public.report_badge(p_token),
    'tasks', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'open_only', true)),
    'submissions', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'reviews', jsonb_build_array('submitted', 'approved'),
      'from', private.today() - 60, 'limit', 300))
  );
end $$;

-- Summary ----------------------------------------------------------------
create or replace function public.report_summary(p_token text, p_from date, p_to date,
    p_department bigint, p_user bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
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
    -- Work status right now, for every task in view (not only the period).
    'status', coalesce((
      select jsonb_object_agg(status, n) from (
        select r.status, count(*) n from public.activity_reports r
        where private.can_see_task(me, r)
          and (r.status <> 'done' or r.report_date between p_from and p_to)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        group by r.status) s), '{}'::jsonb),
    'review', coalesce((
      select jsonb_object_agg(review, n) from (
        select r.review, count(*) n from public.activity_reports r
        where private.can_see_task(me, r)
          and r.report_date between p_from and p_to
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        group by r.review) s), '{}'::jsonb),
    'departments', coalesce((
      select jsonb_agg(x order by x->>'position', x->>'name') from (
        select jsonb_build_object(
          'id', d.id, 'name', d.name, 'position', lpad(d.position::text, 6, '0'),
          'activities', count(r.id) filter (where r.report_date between p_from and p_to),
          'completed', count(r.id) filter (where r.report_date between p_from and p_to
                                           and r.review = 'approved'),
          'open', count(r.id) filter (where r.status <> 'done'),
          'blocked', count(r.id) filter (where r.status = 'blocked'),
          'awaiting', count(r.id) filter (where r.review = 'submitted'),
          'people', count(distinct r.user_id) filter (where r.report_date between p_from and p_to),
          'outputs', coalesce((
            select jsonb_object_agg(k, total) from (
              select o.key k, sum((o.value #>> '{}')::int) total
              from public.activity_reports r2, jsonb_each(r2.outputs) o
              where r2.department_id = d.id
                and private.can_see_task(me, r2)
                and r2.report_date between p_from and p_to
                and (p_user is null or r2.user_id = p_user)
              group by o.key) t), '{}'::jsonb)) x
        from public.departments d
        left join public.activity_reports r
          on r.department_id = d.id
         and (r.status <> 'done' or r.report_date between p_from and p_to)
         and private.can_see_task(me, r)
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
        'open', (select count(*) from public.activity_reports r
                 where r.user_id = u.id and r.status <> 'done'),
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
        where r.status <> 'done' and r.due_date < today
          and private.can_see_task(me, r)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.due_date limit 200) r), '[]'::jsonb),
    'attention', coalesce((
      select jsonb_agg(private.report_json(r) order by r.updated_at desc, r.id desc) from (
        select * from public.activity_reports r
        where (r.status = 'blocked' or r.review = 'returned'
               or (r.urgency = 'urgent' and r.status <> 'done'))
          and private.can_see_task(me, r)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.updated_at desc limit 200) r), '[]'::jsonb)
  );
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function
  public.reports_meta(text), public.report_list(text, jsonb),
  public.report_save(text, jsonb), public.report_review(text, bigint, text, text),
  public.report_delete(text, bigint), public.report_comments(text, bigint),
  public.report_comment_add(text, bigint, text), public.report_comment_delete(text, bigint),
  public.report_history(text, bigint), public.report_badge(text),
  public.report_notifications(text), public.report_notifications_read(text, bigint[]),
  public.report_start(text),
  public.report_summary(text, date, date, bigint, bigint) from public;
grant execute on function
  public.reports_meta(text), public.report_list(text, jsonb),
  public.report_save(text, jsonb), public.report_review(text, bigint, text, text),
  public.report_delete(text, bigint), public.report_comments(text, bigint),
  public.report_comment_add(text, bigint, text), public.report_comment_delete(text, bigint),
  public.report_history(text, bigint), public.report_badge(text),
  public.report_notifications(text), public.report_notifications_read(text, bigint[]),
  public.report_start(text),
  public.report_summary(text, date, date, bigint, bigint) to anon, authenticated;
