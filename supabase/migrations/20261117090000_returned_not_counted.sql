-- Returned tasks no longer count as submitted: Team figures, "who has
-- reported" and department totals only count work that is waiting for
-- review or approved. The date is set again when it is resubmitted.

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
      -- Returned work isn't a submission any more: it counts again (for the
      -- day it is resubmitted) only when it is resubmitted.
      report_date = case when p_decision = 'returned' then null
                         else coalesce(r.report_date, private.today()) end,
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

update public.activity_reports
   set report_date = null
 where review = 'returned' and report_date is not null;
