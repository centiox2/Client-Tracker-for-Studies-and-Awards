-- Keep editor identities in a private table. The public sync log keeps its schema.
create table private.application_status_audit (
  change_id bigint primary key references public.application_changes(id) on delete cascade,
  editor_name text,
  edited_at timestamptz
);
alter table private.application_status_audit enable row level security;
revoke all on private.application_status_audit from public, anon, authenticated;

-- The app's explicit Airtable Sync now action can discover Status-only audit
-- fields after the base owner adds them, without extra calls on scheduled sync.
create or replace function private.airtable_refresh_status_fields()
returns void language plpgsql security definer set search_path = '' as $$
declare c private.airtable_config; response jsonb; editor text; changed_at text;
begin
  select * into c from private.airtable_config where id=1;
  if c.id is null then return; end if;
  response := private.airtable_get('meta/bases/' || c.base_id || '/tables');
  if response->>'status' <> '200' then return; end if;
  select max(f->>'id') filter(where f->>'type'='lastModifiedBy'),
         max(f->>'id') filter(where f->>'type'='lastModifiedTime')
  into editor, changed_at
  from jsonb_array_elements(coalesce(response#>'{body,tables}','[]')) t
  cross join lateral jsonb_array_elements(t->'fields') f
  where t->>'id'=c.table_id
    and f#>'{options,referencedFieldIds}'=jsonb_build_array(c.fields->>'status');
  update private.airtable_config
  set fields = (fields - 'status_editor' - 'status_edited_at')
    || jsonb_strip_nulls(jsonb_build_object('status_editor',editor,'status_edited_at',changed_at))
  where id=1;
end $$;
revoke all on function private.airtable_refresh_status_fields() from public, anon, authenticated;

create or replace function private.applications_apply(p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  v_now text := private.kenya_now_text();
  v_first boolean;
  v_total int;
  v_added int;
  v_changed int;
  v_removed int;
  v_import bigint;
  v_base bigint;
  m record;
  fields text[] := array['rto','country','doc_date','app_date','offer_date',
    'coe_date','status','assignee','todo','follow_up'];
begin
  select * into c from private.airtable_config where id = 1;
  perform set_config('client_min_messages', 'warning', true);
  drop table if exists _in, _diff, _new, _gone;
  v_first := not exists (select 1 from public.applications)
         and not exists (select 1 from public.application_imports);

  -- The incoming applications, cleaned like the CSV.
  create temp table _in on commit drop as
  with raw as (
    select r.position, r.rec_id,
      private.airtable_text(r.fields->(c.fields->>'student')) as student,
      private.airtable_text(r.fields->(c.fields->>'rto')) as rto,
      private.airtable_text(r.fields->(c.fields->>'country')) as country,
      private.airtable_date(r.fields->(c.fields->>'doc_date')) as doc_date,
      private.airtable_date(r.fields->(c.fields->>'app_date')) as app_date,
      private.airtable_date(r.fields->(c.fields->>'offer_date')) as offer_date,
      private.airtable_date(r.fields->(c.fields->>'coe_date')) as coe_date,
      private.airtable_text(r.fields->(c.fields->>'status')) as status,
      nullif(r.fields->(c.fields->>'status_editor')->>'name','') as status_editor,
      case when pg_input_is_valid(r.fields->>(c.fields->>'status_edited_at'),'timestamp with time zone')
        then (r.fields->>(c.fields->>'status_edited_at'))::timestamptz end as status_edited_at,
      private.airtable_text(r.fields->(c.fields->>'assignee')) as assignee,
      private.airtable_text(r.fields->(c.fields->>'todo'), true) as todo,
      private.airtable_text(r.fields->(c.fields->>'follow_up'), true) as follow_up
    from private.airtable_records r
  ), kept as (
    select raw.*,
      (row_number() over (order by position, rec_id) - 1)::int as pos,
      lower(student) as base,
      lower(concat_ws(' · ', nullif(rto, ''), nullif(country, ''))) as place
    from raw where student <> ''
  ), places as (
    select base, count(distinct place) as n from kept group by base
  ), keyed as (
    select k.*, case when p.n > 1 and k.place <> '' then k.base || ' · ' || k.place
                     else k.base end as key0
    from kept k join places p using (base)
  )
  select keyed.*,
    case when row_number() over (partition by key0 order by pos) = 1 then key0
         else key0 || ' #' || row_number() over (partition by key0 order by pos) end as app_key
  from keyed;

  v_total := (select count(*) from _in);
  if v_total = 0 then
    -- An empty read never wipes the applications (Airtable hiccup, wrong
    -- view): it's refused instead.
    raise exception 'airtable_empty' using errcode = 'P0001';
  end if;

  -- Same-name students used to be told apart by their order; a stored
  -- application under an old key that matches an incoming one on name,
  -- institution and country takes the new key, with its history.
  for m in
    select distinct on (a.app_key) i.app_key as new_key, a.app_key as old_key
    from _in i
    join public.applications a
      on lower(a.student) = lower(i.student) and lower(a.rto) = lower(i.rto)
     and lower(a.country) = lower(i.country)
    where not exists (select 1 from public.applications x where x.app_key = i.app_key)
      and not exists (select 1 from _in y where y.app_key = a.app_key)
    order by a.app_key, i.pos
  loop
    if exists (select 1 from public.applications where app_key = m.new_key) then
      continue;                         -- taken by an earlier match
    end if;
    update public.applications set app_key = m.new_key where app_key = m.old_key;
    update public.application_changes set app_key = m.new_key where app_key = m.old_key;
  end loop;

  -- What differs.
  create temp table _diff on commit drop as
  select i.app_key, i.student, f.field, coalesce(f.old, '') as old_value,
         coalesce(f.new, '') as new_value
  from _in i
  join public.applications a on a.app_key = i.app_key
  cross join lateral (values
    ('rto', a.rto, i.rto), ('country', a.country, i.country),
    ('doc_date', a.doc_date, i.doc_date), ('app_date', a.app_date, i.app_date),
    ('offer_date', a.offer_date, i.offer_date), ('coe_date', a.coe_date, i.coe_date),
    ('status', a.status, i.status), ('assignee', a.assignee, i.assignee),
    ('todo', a.todo, i.todo), ('follow_up', a.follow_up, i.follow_up)
  ) as f(field, old, new)
  where coalesce(f.old, '') <> coalesce(f.new, '');

  create temp table _new on commit drop as
  select i.app_key from _in i
  where not exists (select 1 from public.applications a where a.app_key = i.app_key);
  create temp table _gone on commit drop as
  select a.app_key, a.student, a.status from public.applications a
  where not exists (select 1 from _in i where i.app_key = a.app_key);
  v_added := (select count(*) from _new);
  v_removed := (select count(*) from _gone);
  v_changed := (select count(distinct app_key) from _diff);

  -- Each statement only when it has something to do (every write tells the
  -- devices to download again).
  if exists (
       select 1 from _in i join public.applications a on a.app_key = i.app_key
       where a.position <> i.pos or a.student <> i.student
          or exists (select 1 from _diff d where d.app_key = i.app_key)) then
    update public.applications a set
      student = i.student, rto = i.rto, country = i.country,
      doc_date = i.doc_date, app_date = i.app_date, offer_date = i.offer_date,
      coe_date = i.coe_date, status = i.status, assignee = i.assignee,
      todo = i.todo, follow_up = i.follow_up, position = i.pos,
      updated_at = case when exists (select 1 from _diff d where d.app_key = i.app_key)
                        then v_now else a.updated_at end
    from _in i
    where a.app_key = i.app_key
      and (a.position <> i.pos or a.student <> i.student
           or exists (select 1 from _diff d where d.app_key = i.app_key));
  end if;

  if v_added > 0 then
    v_base := private.applications_next_id();
    insert into public.applications (id, app_key, student, rto, country,
      doc_date, app_date, offer_date, coe_date, status, assignee, todo,
      follow_up, position, updated_at)
    select v_base + row_number() over (order by i.pos), i.app_key, i.student,
      i.rto, i.country, i.doc_date, i.app_date, i.offer_date, i.coe_date,
      i.status, i.assignee, i.todo, i.follow_up, i.pos, v_now
    from _in i join _new n using (app_key);
  end if;

  if v_removed > 0 then
    delete from public.applications a using _gone g where a.app_key = g.app_key;
  end if;

  if v_first or v_added + v_changed + v_removed > 0 then
    v_import := private.applications_next_id();
    insert into public.application_imports (id, imported_at, file_name, total,
      added, changed, removed, device)
    values (v_import, v_now, p_label, v_total, v_added, v_changed, v_removed,
            'Airtable sync');
    if not v_first then
      v_base := private.applications_next_id();
      -- In the CSV upload's order: each application in turn (added, or its
      -- changed fields), then the removed ones.
      insert into public.application_changes (id, import_id, app_key, student,
        field, old_value, new_value, changed_at)
      select v_base + row_number() over (order by grp, pos, ord), v_import,
        app_key, student, field, old_value, new_value, v_now
      from (
        select 1 as grp, i.pos, 0 as ord, i.app_key, i.student,
               'added' as field, '' as old_value, i.status as new_value
        from _in i join _new n using (app_key)
        union all
        select 1, i.pos, array_position(fields, d.field), d.app_key,
               d.student, d.field, d.old_value, d.new_value
        from _diff d join _in i using (app_key)
        union all
        select 2, 0, 0, g.app_key, g.student, 'removed', g.status, ''
        from _gone g
      ) ch;

      insert into private.application_status_audit(change_id,editor_name,edited_at)
      select log.id,left(i.status_editor,120),i.status_edited_at
      from public.application_changes log join _in i using(app_key)
      where log.import_id=v_import and log.field='status'
        and i.status_edited_at<=now()
        and i.status_edited_at is not null;
    end if;
  end if;

  return jsonb_build_object('total', v_total, 'added', v_added,
    'changed', v_changed, 'removed', v_removed, 'first', v_first);
end $$;

create or replace function public.airtable_sync_now(p_token text, p_full boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  b jsonb := private.airtable_budget();
begin
  if r not in ('admin', 'admin_team') or (p_full and r <> 'admin') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if private.airtable_calls_this_month() >= (b->>'stop_manual')::int then
    raise exception 'airtable_budget' using errcode = 'P0001';
  end if;
  if r='admin' and (p_full or exists (
      select 1 from private.airtable_config where id=1
        and not (fields ?& array['status_editor','status_edited_at']))) then
    begin
      perform private.airtable_refresh_status_fields();
    exception when others then
      -- Metadata is optional. A metadata outage must never prevent a sync.
      null;
    end;
  end if;
  return private.airtable_run(case when p_full then 'full' else 'changes' end,
                              'Airtable (Sync now)');
end $$;

create or replace function private.ai_summary_template_facts() returns jsonb
language sql security definer set search_path = '' set timezone = 'Africa/Nairobi' as $$
with bounds as (
 select private.today() as day, date_trunc('week', private.today())::date as week_start,
        private.today()::timestamp at time zone 'Africa/Nairobi' as starts_at
), events as (
 select c.id,c.app_key,c.student,c.field,trim(coalesce(c.old_value,'')) as old_value,
        trim(coalesce(c.new_value,'')) as new_value,a.editor_name,a.edited_at is not null as exact_time,
        coalesce(a.edited_at,case when pg_input_is_valid(c.changed_at,'timestamp with time zone')
          then c.changed_at::timestamptz end) as event_at
 from public.application_changes c left join private.application_status_audit a on a.change_id=c.id
), changes as (
 select e.* from events e cross join bounds b
 where e.event_at between b.starts_at and now()
), touched as (
 select app_key, bool_or(field='status') as status_changed,
        bool_or(field='coe_date' and old_value='' and new_value<>'') as coe_logged
 from changes group by app_key
), assignment_counts as (
 select trim(coalesce(a.assignee,'')) as label,
        count(a.app_key) as total, count(t.app_key) as updated,
        count(*) filter(where t.status_changed) as statuses,
        count(*) filter(where t.coe_logged) as coes
 from public.applications a full join touched t using(app_key)
 group by 1
), movements as (
 select old_value as "from", new_value as "to", count(distinct app_key) as count
 from changes where field='status' group by 1,2
), reassignments as (
 select old_value as "from", new_value as "to", count(distinct app_key) as count
 from changes where field='assignee' group by 1,2
), purposes as (
 select coalesce(nullif(trim(purpose),''),'Unspecified') as purpose,
        count(*) as entries, count(*) filter(where amount_cents>0) as payments,
        count(*) filter(where amount_cents<0) as refunds,
        coalesce(sum(amount_cents) filter(where amount_cents>0),0) as gross_cents,
        coalesce(-sum(amount_cents) filter(where amount_cents<0),0) as refunded_cents,
        coalesce(sum(amount_cents),0) as net_cents
 from public.revenue_entries cross join bounds b
 where date=b.day::text group by 1
)
select jsonb_build_object(
 'week', (select jsonb_build_object('start',b.week_start,
   'days',count(distinct d.date) filter(where c.new_clients+c.existing_clients>0),
   'new',coalesce(sum(c.new_clients),0), 'existing',coalesce(sum(c.existing_clients),0))
   from public.client_counts c join public.work_days d on d.id=c.day_id
   where d.date between b.week_start::text and b.day::text and not exists (
     select 1 from public.staff_day_off o where o.day_id=d.id and o.staff_id=c.staff_id)),
 'purposes', coalesce((select jsonb_agg(to_jsonb(p) order by net_cents desc, purpose) from purposes p),'[]'),
 'assignees', coalesce((select jsonb_agg(to_jsonb(a) order by lower(label),label) from assignment_counts a),'[]'),
 'status_events', coalesce((select jsonb_agg(jsonb_build_object(
   'client', student, 'changed_by', editor_name, 'from', old_value, 'to', new_value,
   'at', event_at, 'exact_time', exact_time) order by event_at,id)
   from changes where field='status'),'[]'),
 'status_moves', coalesce((select jsonb_agg(to_jsonb(m) order by count desc,"from","to") from movements m),'[]'),
 'reassignments', coalesce((select jsonb_agg(to_jsonb(r) order by count desc,"from","to") from reassignments r),'[]'),
 'reassigned', (select count(distinct app_key) from changes where field='assignee'),
 'milestones', (select jsonb_build_object(
    'documents_submitted', count(*) filter(where doc_date=b.day::text),
    'applications_submitted', count(*) filter(where app_date=b.day::text),
    'coes_issued', count(*) filter(where coe_date=b.day::text))
    from public.applications),
 'shared_done_today', (select count(*) from public.todo_team_items
   where not deleted and done and done_at between b.starts_at and now())
) from bounds b;
$$;

create or replace function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' set timezone='Africa/Nairobi' as $$
-- Legacy timestamps without an offset were recorded in Nairobi local time.
with changes_today as (
  select app_key, field, old_value, new_value
  from public.application_changes c left join private.application_status_audit a on a.change_id=c.id
  where coalesce(a.edited_at,case when pg_input_is_valid(c.changed_at,'timestamp with time zone')
    then c.changed_at::timestamptz end) between
    (private.today()::timestamp at time zone 'Africa/Nairobi') and now()
), application_updates as (
  select jsonb_build_object(
    'applications_touched', count(distinct app_key),
    'added', count(distinct app_key) filter (where field = 'added'),
    'removed', count(distinct app_key) filter (where field = 'removed'),
    'statuses_changed', count(distinct app_key) filter (where field = 'status'),
    'documents_updated', count(distinct app_key) filter (where field = 'doc_date'),
    'submission_dates_updated', count(distinct app_key) filter (where field = 'app_date'),
    'offers_logged', count(distinct app_key) filter (
      where field = 'offer_date' and trim(old_value) = '' and trim(new_value) <> ''
    ),
    'coes_logged', count(distinct app_key) filter (
      where field = 'coe_date' and trim(old_value) = '' and trim(new_value) <> ''
    ),
    'offer_or_coe_dates_corrected', count(distinct app_key) filter (
      where field in ('offer_date', 'coe_date') and trim(old_value) <> ''
    ),
    'follow_ups_updated', count(distinct app_key) filter (where field in ('todo', 'follow_up'))
  ) as counts
  from changes_today
)
select jsonb_build_object('date',private.today(),'timezone','Africa/Nairobi','cutoff_at',now(),
 'template_facts',private.ai_summary_template_facts(),
 'weekly_tracker',(select jsonb_build_object('today',coalesce(sum(c.new_clients+c.existing_clients) filter(where d.date=private.today()::text),0),
 'today_new',coalesce(sum(c.new_clients) filter(where d.date=private.today()::text),0),
 'today_existing',coalesce(sum(c.existing_clients) filter(where d.date=private.today()::text),0),
 'month_total',coalesce(sum(c.new_clients+c.existing_clients),0),
 'month_new',coalesce(sum(c.new_clients),0),'month_existing',coalesce(sum(c.existing_clients),0))
 from public.client_counts c join public.work_days d on d.id=c.day_id
 where d.date>=date_trunc('month',private.today())::date::text and d.date<=private.today()::text
 and not exists(select 1 from public.staff_day_off o where o.day_id=c.day_id and o.staff_id=c.staff_id)),
 'revenue',(select jsonb_build_object('currency',coalesce(nullif(trim((select value from public.app_settings where key='currency')),''),'KSh'),'today_cents',coalesce(sum(amount_cents) filter(where date=private.today()::text),0),
 'month_net_cents',coalesce(sum(amount_cents),0),
 'today_amount',coalesce(sum(amount_cents) filter(where date=private.today()::text),0)/100.0,
 'month_net_amount',coalesce(sum(amount_cents),0)/100.0,
 'amount_note','Amounts are currency units. The *_cents fields are storage hundredths, not whole currency.') from public.revenue_entries
 where date>=date_trunc('month',private.today())::date::text and date<=private.today()::text),
 'applications',(select jsonb_build_object('updates_today',(select counts from application_updates),'total',count(*),'with_offer',count(*) filter(where nullif(offer_date,'') is not null),
 'with_coe',count(*) filter(where nullif(coe_date,'') is not null),'by_status',
 (select coalesce(jsonb_object_agg(status,n),'{}'::jsonb) from (select coalesce(nullif(status,''),'Unspecified') status,count(*) n from public.applications group by 1) x)) from public.applications),
 'daily_reports',(select jsonb_build_object('today',count(*) filter(where report_date=private.today()),
 'open',count(*) filter(where status<>'done' or review='returned'),
 'submitted_today',count(*) filter(where submitted_at>=private.today()::timestamp at time zone 'Africa/Nairobi'),
 'blocked',count(*) filter(where status='blocked'),
 'overdue',count(*) filter(where (status<>'done' or review='returned') and due_date<private.today()),
 'by_status',coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from public.activity_reports where report_date=private.today() group by status) x),'{}'::jsonb))
 from public.activity_reports where report_date<=private.today()),
 'team_todo',(select jsonb_build_object('open',count(*) filter(where not done),'done',count(*) filter(where done)) from public.todo_team_items where not deleted),
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*),
 'activity',private.ai_summary_staff_activity()) from public.staff));
$$;

create or replace function public.ai_summary_finish(p_run_id uuid,p_content jsonb default null,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job private.ai_summary_jobs;
begin
 if p_content is not null and (jsonb_typeof(p_content)<>'object' or length(p_content::text)>case when p_content#>>'{template,version}'='1' then 1000000 else 40000 end) then raise exception 'invalid_summary'; end if;
 select * into job from private.ai_summary_jobs where run_id=p_run_id and status='running' and lease_until>now() for update;
 if job.id is null then return; end if;
 update private.ai_summary_jobs set status=case when p_content is null then 'failed' else 'ready' end,
 error_code=case when p_content is null then left(coalesce(p_error,'generation_failed'),80) else null end where id=job.id;
 if p_content is null then return; end if;
 insert into private.ai_summaries(summary_date,status,run_id,attempts,lease_until,cutoff_at,generated_at,model,content,input_snapshot,error_code)
 values(job.summary_date,'ready',p_run_id,1,job.lease_until,job.cutoff_at,now(),job.model,p_content,job.input_snapshot,null)
 on conflict(summary_date) do update set status='ready',run_id=excluded.run_id,attempts=1,
 lease_until=excluded.lease_until,cutoff_at=excluded.cutoff_at,generated_at=excluded.generated_at,
 model=excluded.model,content=excluded.content,input_snapshot=excluded.input_snapshot,error_code=null
 where private.ai_summaries.cutoff_at<=excluded.cutoff_at;
end $$;
