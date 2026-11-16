-- Fixes from the November security and bug review (findings in brackets).
-- Safe to run more than once.

-- ---------------------------------------------------------------------
-- [3] A temporary password gives a sign-in that can only choose a new
-- password (or sign out). Every other function refuses it. A switched-off
-- account's sign-ins are refused everywhere, not only where token_user
-- was used.

-- Any live sign-in, temporary or not: for choosing the new password,
-- checking the sign-in and signing out.
create or replace function private.token_user_any(p_token text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid bigint;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  select t.user_id into uid
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active
    where t.token_hash = h and t.expires_at > now();
  if uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return uid;
end $$;

create or replace function private.token_user(p_token text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid bigint;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  select t.user_id into uid
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id and u.active and not u.must_change
    where t.token_hash = h and t.expires_at > now();
  if uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return uid;
end $$;

create or replace function private.token_role(p_token text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  r text;
  h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  -- Old shared-profile sign-ins have no account (user_id is null).
  select t.role into r
    from private.admin_tokens t
    left join private.app_users u on u.id = t.user_id
    where t.token_hash = h and t.expires_at > now()
      and (t.user_id is null or (u.active and not u.must_change));
  if r is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  perform private.note_actor(h);
  return r;
end $$;

create or replace function public.user_session(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.token_user_any(p_token);
begin
  update private.admin_tokens
    set expires_at = now() + case when remember then interval '30 days' else interval '1 day' end
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  return private.user_json(uid);
end $$;

create or replace function public.user_change_password(p_token text, p_current text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid bigint := private.token_user_any(p_token);
  h text;
begin
  perform private.check_password(p_new);
  select hash into h from private.app_users where id = uid;
  if extensions.crypt(coalesce(p_current, ''), h) <> h then
    perform pg_sleep(0.5);
    raise exception 'wrong_password' using errcode = '28P01';
  end if;
  if p_new = p_current then
    raise exception 'same_password' using errcode = '22023';
  end if;
  update private.app_users
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        must_change = false, updated_at = now()
    where id = uid;
  delete from private.admin_tokens
    where user_id = uid
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

create or replace function public.user_session_touch(p_token text, p_device text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.token_user_any(p_token);
  update private.admin_tokens
    set device = left(nullif(trim(coalesce(p_device, '')), ''), 80),
        last_seen = now()
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- ---------------------------------------------------------------------
-- [2] Page access is enforced here too: data for a page an account may
-- not open is not sent to it, and changes to it are refused.

-- The pages the sign-in's account may open (null: all of them).
create or replace function private.token_pages(p_token text)
returns text[] language sql stable security definer set search_path = '' as $$
  select u.pages
    from private.admin_tokens t
    join private.app_users u on u.id = t.user_id
    where t.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- Which pages show each synced table.
create or replace function private.table_pages(p_table text)
returns text[] language sql immutable set search_path = '' as $$
  select case
    when p_table in ('revenue_entries', 'revenue_changes') then array['revenue']
    when p_table in ('applications', 'application_imports', 'application_changes')
      then array['applications', 'home', 'reports']
    when p_table = 'app_settings' then null
    else array['home', 'week', 'history', 'staff', 'reports'] end;
$$;

create or replace function private.may_sync(p_pages text[], p_table text)
returns boolean language sql immutable set search_path = '' as $$
  select p_pages is null or private.table_pages(p_table) is null
      or p_pages && private.table_pages(p_table);
$$;

create or replace function public.sync_read(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  pg text[] := private.token_pages(p_token);
  money boolean := r in ('admin', 'director') and private.may_sync(pg, 'revenue_entries');
  tracker boolean := private.may_sync(pg, 'client_counts');
  apps boolean := private.may_sync(pg, 'applications');
begin
  return jsonb_build_object(
    'staff',           case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.staff t), '[]') else '[]' end,
    'weeks',           case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.weeks t), '[]') else '[]' end,
    'work_days',       case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.work_days t), '[]') else '[]' end,
    'client_counts',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.client_counts t), '[]') else '[]' end,
    'staff_day_off',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.staff_day_off t), '[]') else '[]' end,
    'day_notes',       case when tracker then coalesce((select jsonb_agg(t order by t.day_id) from public.day_notes t), '[]') else '[]' end,
    'app_settings',    coalesce((select jsonb_agg(t order by t.key) from public.app_settings t), '[]'),
    'count_changes',   case when tracker then coalesce((select jsonb_agg(t order by t.id) from public.count_changes t), '[]') else '[]' end,
    'revenue_entries', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_entries t), '[]') else '[]' end,
    'revenue_changes', case when money then coalesce((select jsonb_agg(t order by t.id) from public.revenue_changes t), '[]') else '[]' end,
    'applications',        case when apps then coalesce((select jsonb_agg(t order by t.id) from public.applications t), '[]') else '[]' end,
    'application_imports', case when apps then coalesce((select jsonb_agg(t order by t.id) from public.application_imports t), '[]') else '[]' end,
    'application_changes', case when apps then coalesce((select jsonb_agg(t order by t.id) from public.application_changes t), '[]') else '[]' end
  );
end $$;

-- ---------------------------------------------------------------------
-- [11] A row older than the one online no longer replaces it: on tables
-- that keep updated_at, the newest edit of a row wins, whichever device
-- sends it last. The sender's next download brings the newer row back.
create or replace function private.upsert_rows(p_table text, p_pk text, p_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sets text;
  newer text := '';
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then return; end if;
  select string_agg(format('%I = excluded.%I', column_name, column_name), ', ')
    into sets
    from information_schema.columns
    where table_schema = 'public' and table_name = p_table
      and column_name <> p_pk;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = p_table
               and column_name = 'updated_at') then
    newer := ' where excluded.updated_at >= t.updated_at';
  end if;
  execute format(
    'insert into public.%I as t select * from jsonb_populate_recordset(null::public.%I, $1) '
    'on conflict (%I) do update set %s%s',
    p_table, p_table, p_pk, sets, newer) using p_rows;
end $$;

-- [12] Rows that another device already made under another id (the same
-- week, day, or person's count for a day) take the id that is online, so
-- the upload goes through and both devices end with the same rows.
create or replace function private.remap(p_rows jsonb, p_col text, p_map jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(case
      when p_map ? (r->>p_col)
        then jsonb_set(r, array[p_col], to_jsonb((p_map->>(r->>p_col))::bigint))
      else r end), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;
$$;

create or replace function private.canonical_ids(p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  up jsonb := coalesce(p_payload->'upserts', '{}'::jsonb);
  wmap jsonb; dmap jsonb; cmap jsonb; omap jsonb;
  t text;
begin
  select coalesce(jsonb_object_agg(r->>'id', w.id), '{}') into wmap
    from jsonb_array_elements(coalesce(up->'weeks', '[]')) r
    join public.weeks w on w.start_date = r->>'start_date'
                       and w.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{weeks}', private.remap(up->'weeks', 'id', wmap));
  up := jsonb_set(up, '{work_days}', private.remap(up->'work_days', 'week_id', wmap));

  select coalesce(jsonb_object_agg(r->>'id', d.id), '{}') into dmap
    from jsonb_array_elements(coalesce(up->'work_days', '[]')) r
    join public.work_days d on d.date = r->>'date'
                           and d.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{work_days}', private.remap(up->'work_days', 'id', dmap));
  foreach t in array array['client_counts', 'staff_day_off', 'day_notes', 'count_changes'] loop
    up := jsonb_set(up, array[t], private.remap(up->t, 'day_id', dmap));
  end loop;

  select coalesce(jsonb_object_agg(r->>'id', c.id), '{}') into cmap
    from jsonb_array_elements(coalesce(up->'client_counts', '[]')) r
    join public.client_counts c on c.day_id = (r->>'day_id')::bigint
                               and c.staff_id = (r->>'staff_id')::bigint
                               and c.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{client_counts}', private.remap(up->'client_counts', 'id', cmap));

  select coalesce(jsonb_object_agg(r->>'id', o.id), '{}') into omap
    from jsonb_array_elements(coalesce(up->'staff_day_off', '[]')) r
    join public.staff_day_off o on o.day_id = (r->>'day_id')::bigint
                               and o.staff_id = (r->>'staff_id')::bigint
                               and o.id <> (r->>'id')::bigint;
  up := jsonb_set(up, '{staff_day_off}', private.remap(up->'staff_day_off', 'id', omap));

  return jsonb_set(p_payload, '{upserts}', up);
end $$;

-- [2] [4] [12] Changes: refused for pages the account may not open, and
-- the protected settings can be neither changed nor deleted by the admin
-- team.
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
  pg text[] := private.token_pages(p_token);
  i int;
  payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if r not in ('admin', 'admin_team') then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if r = 'admin_team' and (
       jsonb_array_length(coalesce(payload->'upserts'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'deletes'->'revenue_entries', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'upserts'->'revenue_changes', '[]')) > 0 or
       jsonb_array_length(coalesce(payload->'deletes'->'revenue_changes', '[]')) > 0 or
       exists (select 1 from jsonb_array_elements(coalesce(payload->'upserts'->'app_settings', '[]')) e
               where e->>'key' in ('currency', 'revenue_purposes')) or
       exists (select 1 from jsonb_array_elements_text(coalesce(payload->'deletes'->'app_settings', '[]')) k
               where k in ('currency', 'revenue_purposes'))) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  for i in 1..array_length(tables, 1) loop
    if not private.may_sync(pg, tables[i]) and (
         jsonb_array_length(coalesce(payload->'upserts'->tables[i], '[]')) > 0 or
         jsonb_array_length(coalesce(payload->'deletes'->tables[i], '[]')) > 0) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
  end loop;
  payload := private.canonical_ids(payload);
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

-- ---------------------------------------------------------------------
-- [8] [17] Reports: a new report sent twice (the reply was lost) is saved
-- once; an approval only stands for what was approved.
alter table public.activity_reports add column if not exists client_op text;
create unique index if not exists activity_reports_client_op
  on public.activity_reports (client_op) where client_op is not null;

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
  v_status text := coalesce(nullif(p_report->>'status', ''), 'to_do');
  v_urgency text := coalesce(nullif(p_report->>'urgency', ''), 'normal');
  v_due date := nullif(p_report->>'due_date', '')::date;
  v_submit boolean := coalesce((p_report->>'submit')::boolean, false);
  v_title text := trim(coalesce(p_report->>'description', ''));
  v_details text := left(trim(coalesce(p_report->>'details', '')), 4000);
  v_reference text := left(trim(coalesce(p_report->>'reference', '')), 200);
  v_outputs jsonb;
  v_op text := nullif(left(trim(coalesce(p_report->>'op', '')), 80), '');
  v_dept bigint;
  v_assigned bigint;
  v_owner bigint;
  v_review text;
  v_report_date date;
  v_submitted timestamptz;
  v_reviewed_by bigint;
  v_reviewed_at timestamptz;
  v_done_on date := nullif(p_report->>'done_on', '')::date;
begin
  select * into u from private.app_users where id = me;
  if rid is null and v_op is not null then
    -- Sent before (the reply never arrived): the same report again.
    v_op := me || ':' || v_op;
    select * into saved from public.activity_reports where client_op = v_op;
    if saved.id is not null then
      return private.report_json(saved);
    end if;
  end if;
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
    if before.review in ('submitted', 'approved') and before.user_id = me
       and before.assigned_by is distinct from me and u.role is distinct from 'admin' then
      raise exception 'already_submitted' using errcode = '42501';
    end if;
    v_owner := before.user_id;
    v_assigned := before.assigned_by;
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

  v_outputs := case when rid is null
    then private.clean_outputs(p_report->'outputs', v_dept)
    else private.clean_outputs(p_report->'outputs', v_dept, before.outputs) end;

  v_review := coalesce(before.review, 'none');
  v_report_date := before.report_date;
  v_submitted := before.submitted_at;
  v_reviewed_by := before.reviewed_by;
  v_reviewed_at := before.reviewed_at;
  if v_submit then
    if v_owner <> me then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
    v_review := 'submitted';
    v_report_date := case
      when v_done_on between private.today() - 7 and private.today() then v_done_on
      else private.today() end;
    v_submitted := now();
    v_reviewed_by := null;
    v_reviewed_at := null;
  elsif rid is not null and v_review in ('submitted', 'approved') then
    if v_status <> 'done' or v_owner <> before.user_id then
      -- Reopened, or now someone else's: no longer a submission.
      v_review := 'none';
      v_report_date := null;
      v_submitted := null;
      v_reviewed_by := null;
      v_reviewed_at := null;
    elsif v_review = 'approved' and (
          left(v_title, 2000) <> before.description
          or v_details <> before.details
          or v_reference <> before.reference
          or v_outputs is distinct from before.outputs
          or v_dept is distinct from before.department_id) then
      -- Changed after approval: back for a fresh review.
      v_review := 'submitted';
      v_reviewed_by := null;
      v_reviewed_at := null;
    end if;
  end if;

  if rid is null then
    insert into public.activity_reports (user_id, department_id, report_date,
        description, details, reference, outputs, status, blocker, urgency,
        due_date, assigned_by, review, submitted_at, client_op)
      values (v_owner, v_dept, v_report_date, left(v_title, 2000),
        v_details, v_reference, v_outputs,
        v_status, left(trim(coalesce(p_report->>'blocker', '')), 1000), v_urgency,
        v_due, v_assigned, v_review, v_submitted, v_op)
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
        details = v_details,
        reference = v_reference,
        outputs = v_outputs,
        status = v_status,
        blocker = case when v_status = 'blocked'
                       then left(trim(coalesce(p_report->>'blocker', '')), 1000) else '' end,
        urgency = v_urgency,
        due_date = v_due,
        review = v_review,
        submitted_at = v_submitted,
        reviewed_by = v_reviewed_by,
        reviewed_at = v_reviewed_at,
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

-- [13] A notification shows the task as it is now only to someone who may
-- still see it; others see what the notification said at the time.
create or replace function public.report_notifications(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'report_id', n.report_id, 'body', n.body,
      'created_at', n.created_at, 'read', n.read_at is not null,
      'actor_name', (select full_name from private.app_users where id = n.actor_id),
      'task', case when r.id is not null then r.description else n.body end,
      'urgency', r.urgency,
      'report', case when r.id is not null then private.report_json(r) end)
      order by n.id desc)
    from (select * from public.report_notifications
          where user_id = me order by id desc limit 60) n
    left join lateral (
      select x.* from public.activity_reports x
       where x.id = n.report_id and private.can_see_task(me, x)) r on true), '[]'::jsonb);
end $$;

-- [27] Lists can be read page by page (exports read every page).
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
  v_offset int := greatest(coalesce((f->>'offset')::int, 0), 0);
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
        and (not v_reviewed_by_me or r.reviewed_by = me)
        and (v_search is null or r.id = v_id or private.search_hit(v_search,
              concat_ws(' ', r.description, r.details, r.reference, r.blocker,
                (select full_name from private.app_users where id = r.user_id),
                (select full_name from private.app_users where id = r.assigned_by),
                (select name from public.departments where id = r.department_id))))
      order by coalesce(r.submitted_at, r.updated_at) desc, r.id desc
      limit v_limit offset v_offset
    ) r), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- [23] To-do details are checked field by field: anything of the wrong
-- kind is left out, so no item can break someone's list.
create or replace function private.todo_extra(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  o jsonb := '{}'::jsonb;
  steps jsonb := '[]'::jsonb;
  outs jsonb := '{}'::jsonb;
  s jsonb;
  k text;
  v jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' or length(p::text) > 20000 then
    return '{}'::jsonb;
  end if;
  foreach k in array array['notes', 'day', 'due', 'repeat', 'done_by'] loop
    if jsonb_typeof(p->k) = 'string' then
      o := o || jsonb_build_object(k, left(p->>k, case k when 'notes' then 4000 else 60 end));
    end if;
  end loop;
  foreach k in array array['later', 'starred', 'new', 'archived', 'auto_ticked'] loop
    if jsonb_typeof(p->k) = 'boolean' then o := o || jsonb_build_object(k, p->k); end if;
  end loop;
  foreach k in array array['pos', 'spawned'] loop
    if jsonb_typeof(p->k) = 'number' then o := o || jsonb_build_object(k, p->k); end if;
  end loop;
  if jsonb_typeof(p->'steps') = 'array' then
    for s in select value from jsonb_array_elements(p->'steps') limit 100 loop
      if jsonb_typeof(s) = 'object' and jsonb_typeof(s->'t') = 'string' then
        steps := steps || jsonb_build_array(
          jsonb_build_object('t', left(s->>'t', 300))
          || case when s->'d' = 'true'::jsonb then '{"d": true}'::jsonb else '{}'::jsonb end);
      end if;
    end loop;
    if jsonb_array_length(steps) > 0 then o := o || jsonb_build_object('steps', steps); end if;
  end if;
  if jsonb_typeof(p->'outputs') = 'object' then
    for k, v in select key, value from jsonb_each(p->'outputs') limit 50 loop
      if jsonb_typeof(v) = 'number' then
        outs := outs || jsonb_build_object(left(k, 60), v);
      end if;
    end loop;
    if outs <> '{}'::jsonb then o := o || jsonb_build_object('outputs', outs); end if;
  end if;
  if jsonb_typeof(p->'client') = 'object' and jsonb_typeof(p->'client'->'key') = 'string' then
    o := o || jsonb_build_object('client', jsonb_build_object(
      'key', left(p->'client'->>'key', 200),
      'name', left(case when jsonb_typeof(p->'client'->'name') = 'string'
                        then p->'client'->>'name' else p->'client'->>'key' end, 200)));
  end if;
  if jsonb_typeof(p->'from') = 'object' and jsonb_typeof(p->'from'->'name') = 'string' then
    o := o || jsonb_build_object('from', jsonb_strip_nulls(jsonb_build_object(
      'id', case when jsonb_typeof(p->'from'->'id') = 'number' then p->'from'->'id' end,
      'name', left(p->'from'->>'name', 200))));
  end if;
  return o;
end $$;

-- Already saved: cleaned the same way.
update public.todo_items set extra = private.todo_extra(extra)
  where extra is distinct from private.todo_extra(extra);
update public.todo_team_items set extra = private.todo_extra(extra)
  where extra is distinct from private.todo_extra(extra);

-- [9] [18] The item limit counts what the list would hold after the
-- change (so deleting and editing always work), and a shared item is
-- only saved to the department it came from.
create or replace function public.todo_sync(p_token text, p_items jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  v_dept bigint;
  n int;
  v_added int;
begin
  select department_id into v_dept from private.app_users where id = me;
  if p_items is null then p_items := '[]'::jsonb; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items where user_id = me and not deleted;
  select count(*) filter (where not coalesce((i->>'deleted')::boolean, false) and t.id is null)
       - count(*) filter (where coalesce((i->>'deleted')::boolean, false) and t.id is not null)
    into v_added
    from jsonb_array_elements(p_items) i
    left join public.todo_items t
      on t.user_id = me and t.id = (i->>'id')::bigint and not t.deleted
   where not coalesce((i->>'team')::boolean, false);
  if v_added > 0 and n + v_added > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at, extra)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes'),
         private.todo_extra(i->'extra')
    from jsonb_array_elements(p_items) i
   where not coalesce((i->>'team')::boolean, false)
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at,
        extra = excluded.extra
    where excluded.changed_at >= t.changed_at;

  if v_dept is not null then
    insert into public.todo_team_items as t
        (department_id, id, title, done, done_at, deleted, changed_at,
         changed_by, extra)
    select v_dept,
           (i->>'id')::bigint,
           left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
           coalesce((i->>'done')::boolean, false),
           (i->>'done_at')::timestamptz,
           coalesce((i->>'deleted')::boolean, false),
           least(coalesce((i->>'changed_at')::timestamptz, now()),
                 now() + interval '5 minutes'),
           me,
           private.todo_extra(i->'extra')
      from jsonb_array_elements(p_items) i
     where coalesce((i->>'team')::boolean, false)
       and jsonb_typeof(i->'dept') = 'number'
       and (i->>'dept')::bigint = v_dept
    on conflict (department_id, id) do update
      set title = excluded.title,
          done = excluded.done,
          done_at = excluded.done_at,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at,
          changed_by = excluded.changed_by,
          extra = excluded.extra
      where excluded.changed_at >= t.changed_at;
  end if;

  update public.todo_items t
     set done = true,
         done_at = coalesce(t.done_at, now()),
         changed_at = now(),
         extra = t.extra || '{"auto_ticked": true}'::jsonb
    from public.activity_reports r
   where t.user_id = me and not t.done and not t.deleted
     and not (t.extra ? 'auto_ticked')
     and r.id = t.sent_id and r.user_id = me
     and r.status = 'done' and r.review in ('submitted', 'approved');

  delete from public.todo_items
   where user_id = me and (
     (deleted and changed_at < now() - interval '30 days') or
     (done and coalesce((extra->>'archived')::boolean, false)
      and done_at < now() - interval '90 days'));
  if v_dept is not null then
    delete from public.todo_team_items
     where department_id = v_dept and (
       (deleted and changed_at < now() - interval '30 days') or
       (done and done_at < now() - interval '90 days'));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
          'sent_id', t.sent_id, 'changed_at', t.changed_at, 'extra', t.extra,
          'report_review', r.review, 'report_status', r.status)
        order by t.id)
      from public.todo_items t
      left join public.activity_reports r
        on r.id = t.sent_id and r.user_id = me
      where t.user_id = me and not t.deleted), '[]'::jsonb),
    'team', case when v_dept is null then null else jsonb_build_object(
      'id', v_dept,
      'name', (select d.name from public.departments d where d.id = v_dept),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id, 'title', t.title, 'done', t.done,
            'done_at', t.done_at, 'changed_at', t.changed_at,
            'extra', t.extra, 'team', true, 'dept', v_dept,
            'changed_by_name', u.full_name)
          order by t.id)
        from public.todo_team_items t
        left join private.app_users u on u.id = t.changed_by
        where t.department_id = v_dept and not t.deleted), '[]'::jsonb))
    end);
end $$;

-- The older save (before 1.8): the same limit rule.
create or replace function public.todo_save(p_token text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  n int;
  v_added int;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
    where user_id = me and not deleted;
  select count(*) filter (where not coalesce((i->>'deleted')::boolean, false) and t.id is null)
       - count(*) filter (where coalesce((i->>'deleted')::boolean, false) and t.id is not null)
    into v_added
    from jsonb_array_elements(p_items) i
    left join public.todo_items t
      on t.user_id = me and t.id = (i->>'id')::bigint and not t.deleted;
  if v_added > 0 and n + v_added > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes')
    from jsonb_array_elements(p_items) i
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at
    where excluded.changed_at >= t.changed_at;

  return public.todo_list(p_token);
end $$;

-- ---------------------------------------------------------------------
-- [14] [19] The online backup holds the to-do lists too, and a restore
-- no longer fails because someone named in an old backup has since been
-- deleted (their name is left blank on what they did).
create or replace function public.admin_backup(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  return jsonb_build_object(
    'departments', coalesce((select jsonb_agg(t order by t.id) from public.departments t), '[]'),
    'activity_reports', coalesce((select jsonb_agg(t order by t.id) from public.activity_reports t), '[]'),
    'activity_changes', coalesce((select jsonb_agg(t order by t.id) from public.activity_changes t), '[]'),
    'report_comments', coalesce((select jsonb_agg(t order by t.id) from public.report_comments t), '[]'),
    'todo_items', coalesce((select jsonb_agg(t order by t.user_id, t.id) from public.todo_items t), '[]'),
    'todo_team_items', coalesce((select jsonb_agg(t order by t.department_id, t.id) from public.todo_team_items t), '[]'),
    'accounts', coalesce((select jsonb_agg(private.user_json(u.id) order by u.id) from private.app_users u), '[]'),
    'audit_log', coalesce((select jsonb_agg(t order by t.id) from private.audit_log t), '[]')
  );
end $$;

-- An account id that still exists, or null.
create or replace function private.known_user(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number'
               and exists (select 1 from private.app_users where id = (p #>> '{}')::bigint)
              then p else 'null'::jsonb end;
$$;

create or replace function public.admin_restore_online(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_dept int; n_rep int; n_chg int; n_com int; n_todo int; n_team int;
begin
  perform private.check_token(p_token);
  insert into public.departments overriding system value
    select * from jsonb_populate_recordset(null::public.departments,
                                           coalesce(p_data->'departments', '[]'))
    on conflict (id) do nothing;
  get diagnostics n_dept = row_count;

  insert into public.activity_reports overriding system value
    select (jsonb_populate_record(null::public.activity_reports,
             x || jsonb_build_object(
               'assigned_by', private.known_user(x->'assigned_by'),
               'reviewed_by', private.known_user(x->'reviewed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_reports', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
      and (x->>'department_id' is null
           or exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint))
    on conflict (id) do nothing;
  get diagnostics n_rep = row_count;

  insert into public.activity_changes overriding system value
    select (jsonb_populate_record(null::public.activity_changes,
             x || jsonb_build_object('changed_by', private.known_user(x->'changed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_changes', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_chg = row_count;

  insert into public.report_comments overriding system value
    select (jsonb_populate_record(null::public.report_comments,
             x || jsonb_build_object('user_id', private.known_user(x->'user_id')))).*
    from jsonb_array_elements(coalesce(p_data->'report_comments', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_com = row_count;

  insert into public.todo_items
    select (jsonb_populate_record(null::public.todo_items,
             x || jsonb_build_object('extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_items', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
    on conflict (user_id, id) do nothing;
  get diagnostics n_todo = row_count;

  insert into public.todo_team_items
    select (jsonb_populate_record(null::public.todo_team_items,
             x || jsonb_build_object(
               'changed_by', private.known_user(x->'changed_by'),
               'extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_team_items', '[]')) x
    where exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint)
    on conflict (department_id, id) do nothing;
  get diagnostics n_team = row_count;

  perform setval(pg_get_serial_sequence('public.departments', 'id'),
                 greatest(coalesce((select max(id) from public.departments), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_reports', 'id'),
                 greatest(coalesce((select max(id) from public.activity_reports), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_changes', 'id'),
                 greatest(coalesce((select max(id) from public.activity_changes), 0), 1));
  perform setval(pg_get_serial_sequence('public.report_comments', 'id'),
                 greatest(coalesce((select max(id) from public.report_comments), 0), 1));
  return jsonb_build_object('departments', n_dept, 'reports', n_rep,
                            'changes', n_chg, 'comments', n_com,
                            'todos', n_todo, 'team_todos', n_team);
end $$;

-- ---------------------------------------------------------------------
-- [16] Airtable calls made before a failure stay counted: the count goes
-- with the error and is added back after the failed part is undone.
create or replace function private.airtable_fetch(p_full boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  s private.airtable_state;
  v_started timestamptz := now();
  v_path text;
  v_offset text;
  v_resp jsonb;
  v_status int;
  v_calls int := 0;
  v_read int := 0;
  v_pos int := 0;
  v_next_pos int;
  v_fields text := '';
  v_seen text[] := '{}';
  rec jsonb;
  f text;
  v_msg text;
  v_detail text;
begin
  select * into c from private.airtable_config where id = 1;
  select * into s from private.airtable_state where id = 1;
  for f in select value from jsonb_each_text(c.fields) loop
    v_fields := v_fields || '&fields%5B%5D=' || f;
  end loop;
  if not p_full and s.cursor_at is null then
    p_full := true;                    -- never read: read everything
  end if;
  select coalesce(max(position), -1) + 1 into v_next_pos from private.airtable_records;

  begin
    loop
      v_path := c.base_id || '/' || c.table_id || '?view=' || c.view_id
        || '&pageSize=100&returnFieldsByFieldId=true' || v_fields;
      if not p_full then
        -- A minute's overlap, so a change made during the last read is caught.
        v_path := v_path || '&filterByFormula=' || extensions.urlencode(format(
          'IS_AFTER(LAST_MODIFIED_TIME(), ''%s'')',
          to_char((s.cursor_at - interval '1 minute') at time zone 'UTC',
                  'YYYY-MM-DD"T"HH24:MI:SS.000"Z"')));
      end if;
      if v_offset is not null then
        v_path := v_path || '&offset=' || extensions.urlencode(v_offset);
      end if;
      v_calls := v_calls + 1;          -- counted before: a call that fails still counts
      v_resp := private.airtable_get(v_path);
      v_status := (v_resp->>'status')::int;
      if v_status <> 200 then
        raise exception '%', case
          when v_status in (401, 403) then 'airtable_token_rejected'
          when v_status = 404 then 'airtable_not_found'
          when v_status = 429 then 'airtable_limit'
          else 'airtable_error_' || v_status end
          using errcode = 'P0001',
                detail = coalesce(v_resp->'body'->'error'->>'message',
                                  v_resp->'body'->>'error', '');
      end if;
      for rec in select value from jsonb_array_elements(v_resp->'body'->'records') loop
        v_read := v_read + 1;
        v_seen := v_seen || (rec->>'id');
        if p_full then
          insert into private.airtable_records as r (rec_id, fields, position, read_at)
            values (rec->>'id', coalesce(rec->'fields', '{}'), v_pos, v_started)
            on conflict (rec_id) do update
              set fields = excluded.fields, position = excluded.position, read_at = excluded.read_at;
          v_pos := v_pos + 1;
        else
          insert into private.airtable_records as r (rec_id, fields, position, read_at)
            values (rec->>'id', coalesce(rec->'fields', '{}'), v_next_pos, v_started)
            on conflict (rec_id) do update
              set fields = excluded.fields, read_at = excluded.read_at;
          if found then v_next_pos := v_next_pos + 1; end if;
        end if;
      end loop;
      v_offset := v_resp->'body'->>'offset';
      exit when v_offset is null;
      if v_calls >= 20 then              -- 2,000 records: something's wrong
        raise exception 'airtable_too_many_pages' using errcode = 'P0001';
      end if;
      perform pg_sleep(0.25);            -- Airtable: at most 5 calls a second
    end loop;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    raise exception '%', v_msg
      using errcode = 'P0001', detail = coalesce(v_detail, ''),
            hint = 'airtable_calls=' || v_calls;
  end;

  if p_full then
    delete from private.airtable_records where not (rec_id = any (v_seen));
  end if;
  update private.airtable_state
    set cursor_at = v_started,
        last_full_at = case when p_full then v_started else last_full_at end
    where id = 1;
  return jsonb_build_object('calls', v_calls, 'read', v_read, 'full', p_full);
end $$;

create or replace function private.airtable_run(p_kind text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_fetch jsonb;
  v_apply jsonb;
  v_result jsonb;
  v_code text;
  v_detail text;
  v_hint text;
  v_calls int := 0;
begin
  if not coalesce((select enabled from private.airtable_config where id = 1), false) then
    return jsonb_build_object('skipped', 'disabled');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('airtable_sync')) then
    return jsonb_build_object('skipped', 'busy');
  end if;
  update private.airtable_state set last_run_at = now(), last_kind = p_kind where id = 1;
  begin
    v_fetch := private.airtable_fetch(p_kind = 'full');
    v_apply := private.applications_apply(p_label);
    v_result := v_apply || v_fetch;
    update private.airtable_state
      set last_ok_at = now(), last_result = v_result, last_error = null
      where id = 1;
    return v_result;
  exception when others then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail,
                            v_hint = pg_exception_hint;
    -- The failure undid the counting too: add back every call made, from
    -- the fetch's result (it finished; the next step failed) or the error.
    if v_fetch is not null then
      v_calls := coalesce((v_fetch->>'calls')::int, 0);
    elsif coalesce(v_hint, '') like 'airtable_calls=%' then
      v_calls := coalesce(nullif(substring(v_hint from '[0-9]+'), '')::int, 0);
    end if;
    if v_calls > 0 then
      insert into private.airtable_usage as u (month, calls)
        values (date_trunc('month', now() at time zone 'Africa/Nairobi')::date, v_calls)
        on conflict (month) do update set calls = u.calls + v_calls;
    end if;
    update private.airtable_state
      set last_error = v_code || case when coalesce(v_detail, '') <> ''
                                      then ': ' || v_detail else '' end,
          last_error_at = now()
      where id = 1;
    return jsonb_build_object('error', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- [24] Error reports: reports from signed-in people have their own daily
-- room, so reports sent without signing in can't use it all up; and one
-- sender without a sign-in can add only a few new kinds a day.
alter table private.error_reports add column if not exists source text not null default '';

create or replace function public.report_error(p_token text, p_report jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  msg text := left(coalesce(p_report ->> 'message', ''), 2000);
  stk text := left(coalesce(p_report ->> 'stack', ''), 8000);
  ver text := left(coalesce(p_report ->> 'version', ''), 40);
  fp text;
  v_who text := '';
  v_source text := '';
  v_headers jsonb;
begin
  if msg = '' then return; end if;
  begin
    if p_token is not null then
      perform private.token_role(p_token);
      v_who := coalesce(current_setting('app.actor', true), '');
    end if;
  exception when others then v_who := '';
  end;
  fp := encode(extensions.digest(msg || '|' || left(stk, 600) || '|' || ver, 'sha256'), 'hex');
  update private.error_reports
    set count = error_reports.count + 1, last_seen = now(),
        who = coalesce(nullif(v_who, ''), error_reports.who)
    where fingerprint = fp;
  if found then return; end if;
  if v_who <> '' then
    if (select count(*) from private.error_reports
        where who <> '' and first_seen > now() - interval '1 day') >= 300 then
      return;
    end if;
  else
    begin
      v_headers := current_setting('request.headers', true)::jsonb;
    exception when others then v_headers := null;
    end;
    v_source := encode(extensions.digest(coalesce(
      split_part(v_headers ->> 'x-forwarded-for', ',', 1),
      v_headers ->> 'cf-connecting-ip', ''), 'sha256'), 'hex');
    if (select count(*) from private.error_reports
        where who = '' and first_seen > now() - interval '1 day') >= 100
       or (select count(*) from private.error_reports
           where who = '' and source = v_source
             and first_seen > now() - interval '1 day') >= 10 then
      return;
    end if;
  end if;
  insert into private.error_reports (fingerprint, message, stack, app_version,
                                     platform, who, source)
  values (fp, msg, stk, ver,
          left(coalesce(p_report ->> 'platform', ''), 40), v_who, v_source);
end $$;

-- The new helpers are for these functions only.
revoke all on function private.token_user_any(text) from public, anon, authenticated;
revoke all on function private.token_pages(text) from public, anon, authenticated;
revoke all on function private.table_pages(text) from public, anon, authenticated;
revoke all on function private.may_sync(text[], text) from public, anon, authenticated;
revoke all on function private.remap(jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function private.canonical_ids(jsonb) from public, anon, authenticated;
revoke all on function private.known_user(jsonb) from public, anon, authenticated;
