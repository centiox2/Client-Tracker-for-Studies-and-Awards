-- Daily reports: quicker entry.
-- - report_save: "done_on" keeps the day work was done when it was saved
--   offline and sent later (up to 7 days back).
-- - report_withdraw: undo a submission that hasn't been reviewed yet.
-- - report_notifications: each carries its task, to open without a lookup.

alter table public.activity_changes
  drop constraint if exists activity_changes_action_check,
  add constraint activity_changes_action_check
    check (action in ('created', 'edited', 'deleted', 'submitted',
                      'approved', 'returned', 'withdrawn'));

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
  -- Saved on a device while offline and sent later: the day it was done.
  v_done_on date := nullif(p_report->>'done_on', '')::date;
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
    v_report_date := case
      when v_done_on between private.today() - 7 and private.today() then v_done_on
      else private.today() end;
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

create or replace function public.report_withdraw(p_token text, p_report bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  r public.activity_reports;
  saved public.activity_reports;
begin
  select * into r from public.activity_reports where id = p_report for update;
  if r.id is null then
    raise exception 'unknown_report' using errcode = '22023';
  end if;
  if r.user_id is distinct from me then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if r.review <> 'submitted' then
    raise exception 'not_submitted' using errcode = '22023';
  end if;
  update public.activity_reports set
      -- Back to how it was: returned work stays returned.
      review = case when (select c.kind from public.report_comments c
                          where c.report_id = p_report
                            and c.kind in ('approved', 'returned')
                          order by c.id desc limit 1) = 'returned'
                    then 'returned' else 'none' end,
      status = 'in_progress', report_date = null,
      submitted_at = null, updated_at = now()
    where id = p_report
    returning * into saved;
  -- The submission's timeline entry and its unread notice go too.
  delete from public.report_comments
    where id = (select max(id) from public.report_comments
                where report_id = p_report and kind = 'submitted');
  delete from public.report_notifications
    where report_id = p_report and kind = 'submitted' and read_at is null;
  insert into public.activity_changes (report_id, changed_by, action, before, after)
    values (p_report, me, 'withdrawn', to_jsonb(r), to_jsonb(saved));
  return private.report_json(saved);
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
      'urgency', (select urgency from public.activity_reports where id = n.report_id),
      -- The task itself, so tapping the notification opens it at once.
      'report', (select private.report_json(r) from public.activity_reports r
                 where r.id = n.report_id and private.can_see_task(me, r)))
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n), '[]'::jsonb);
end $$;

grant execute on function public.report_withdraw(text, bigint) to anon, authenticated;
