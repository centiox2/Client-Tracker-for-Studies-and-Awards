-- ===== Fixes from review (2026-11-09) =====

-- 1. Outputs: the number check now guards the conversion itself (PostgreSQL
--    may evaluate WHERE conditions in any order, so a value like "3 files"
--    could fail the whole save instead of being left out). Keys a report
--    already had stay allowed ([p_keep]), so editing an old report doesn't
--    lose a count whose output the admin has since renamed or removed.
drop function if exists private.clean_outputs(jsonb, bigint);
create or replace function private.clean_outputs(
  p_outputs jsonb, p_department bigint, p_keep jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(e.key, least(e.n, 100000)::int), '{}'::jsonb)
  from (
    select o.key,
           case when (o.value #>> '{}') ~ '^\s*[0-9]{1,9}(\.[0-9]+)?\s*$'
                then round((o.value #>> '{}')::numeric) end as n
    from jsonb_each(case when jsonb_typeof(p_outputs) = 'object'
                         then p_outputs else '{}'::jsonb end) o
  ) e
  where e.n is not null and e.n > 0
    and (e.key in (select x->>'key' from public.departments d,
                   jsonb_array_elements(d.outputs) x where d.id = p_department)
         or (jsonb_typeof(p_keep) = 'object' and p_keep ? e.key));
$$;

-- report_save: same as before, but an edit keeps the report's existing
-- output keys.
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

-- 2. The dashboard's figures can be for one person (p_user), so a Staff
--    Activity Report's totals, departments, compliance and attention lists
--    are that person's, not everyone's.
drop function if exists public.report_summary(text, date, date, bigint);
create or replace function public.report_summary(
  p_token text, p_from date, p_to date, p_department bigint, p_user bigint default null)
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
          and (p_user is null or r.user_id = p_user)
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
                and (p_user is null or r2.user_id = p_user)
              group by o.key) t), '{}'::jsonb)) x
        from public.departments d
        left join public.activity_reports r
          on r.department_id = d.id
         and r.report_date between p_from and p_to
         and private.can_see_report(me, r.user_id, r.department_id)
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
        where r.status <> 'completed' and r.due_date < today
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.due_date limit 200) r), '[]'::jsonb),
    'attention', coalesce((
      select jsonb_agg(private.report_json(r) order by r.report_date desc, r.id desc) from (
        select * from public.activity_reports r
        where r.status in ('blocked', 'escalated')
          and private.can_see_report(me, r.user_id, r.department_id)
          and (p_department is null or r.department_id = p_department)
          and (p_user is null or r.user_id = p_user)
        order by r.report_date desc limit 200) r), '[]'::jsonb)
  );
end $$;

-- 3. The old shared-profile functions (still used by old app builds until
--    every device is updated) signed out tokens by role, which now includes
--    personal accounts. They only touch the old shared-profile tokens now.
create or replace function public.admin_set_profile_password(
  p_token text, p_role text, p_password text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  if p_role not in ('admin_team', 'director', 'team') then
    raise exception 'unknown_profile' using errcode = '22023';
  end if;
  if coalesce(p_password, '') <> '' and length(p_password) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  update private.profile_secret
    set hash = case when coalesce(p_password, '') = '' then null
                    else extensions.crypt(p_password, extensions.gen_salt('bf', 10)) end,
        updated_at = now()
    where role = p_role;
  delete from private.admin_tokens where role = p_role and user_id is null;
end $$;

create or replace function public.admin_set_password(p_token text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_token(p_token);
  if length(coalesce(p_new, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens
    where role = 'admin' and user_id is null
      and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

create or replace function public.admin_recover(p_code text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  stored text;
  code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(coalesce(p_new, '')) < 4 then
    raise exception 'password_too_short' using errcode = '22023';
  end if;
  if length(code) = 16 then
    code := substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' ||
            substr(code, 9, 4) || '-' || substr(code, 13, 4);
  end if;
  select recovery_hash into stored from private.admin_secret where id = 1;
  if stored is null or extensions.crypt(code, stored) <> stored then
    perform pg_sleep(1);
    raise exception 'wrong_recovery_code' using errcode = '28000';
  end if;
  update private.admin_secret
    set hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
        recovery_hash = null,
        updated_at = now()
    where id = 1;
  delete from private.admin_tokens where user_id is null;
  return private.new_token();
end $$;

-- ---- Access ------------------------------------------------------------------

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.report_summary(text, date, date, bigint, bigint),
  public.report_save(text, jsonb), public.admin_set_profile_password(text, text, text),
  public.admin_set_password(text, text), public.admin_recover(text, text) from public;
grant execute on function public.report_summary(text, date, date, bigint, bigint),
  public.report_save(text, jsonb), public.admin_set_profile_password(text, text, text),
  public.admin_set_password(text, text), public.admin_recover(text, text) to anon, authenticated;
