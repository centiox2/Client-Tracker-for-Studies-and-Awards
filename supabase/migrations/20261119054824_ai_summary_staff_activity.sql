-- Attribute only recorded activity to its owner or recorded actor.
create function private.ai_summary_staff_activity() returns jsonb
language sql security definer set search_path = '' as $$
with bounds as (
  select private.today() as day,
         private.today()::timestamp at time zone 'Africa/Nairobi' as started_at
), accounts as (
  select u.id, case when s.id is null then 'account:' || u.id else 'staff:' || s.id end as person,
         coalesce(s.name, u.full_name) as name
  from private.app_users u left join public.staff s on s.id = u.staff_id
), clients as (
  select 'staff:' || c.staff_id as person, s.name,
         sum(c.new_clients) as new_clients, sum(c.existing_clients) as existing_clients
  from public.client_counts c
  join public.work_days d on d.id = c.day_id
  join public.staff s on s.id = c.staff_id
  cross join bounds
  where d.date = bounds.day::text and c.new_clients + c.existing_clients > 0
    and not exists (
      select 1 from public.staff_day_off o where o.day_id = c.day_id and o.staff_id = c.staff_id
    )
  group by c.staff_id, s.name
), edited_reports as (
  select a.person, a.name, count(distinct c.report_id) as work_items_updated
  from public.activity_changes c join accounts a on a.id = c.changed_by
  cross join bounds
  where c.changed_at between bounds.started_at and now()
    and c.action in ('created', 'edited', 'approved', 'returned')
  group by a.person, a.name
), submitted as (
  select a.person, a.name, r.department_id, r.outputs
  from public.activity_reports r join accounts a on a.id = r.user_id
  cross join bounds
  where r.submitted_at between bounds.started_at and now()
), submitted_counts as (
  select person, name, count(*) as reports_submitted from submitted group by person, name
), output_counts as (
  select s.person, field->>'label' as label, sum(o.value::text::numeric) as total
  from submitted s join public.departments d on d.id = s.department_id
  cross join lateral jsonb_each(s.outputs) o
  join lateral jsonb_array_elements(d.outputs) field on field->>'key' = o.key
  where case when jsonb_typeof(o.value) = 'number' then o.value::text::numeric > 0 else false end
    and nullif(trim(field->>'label'), '') is not null
  group by s.person, field->>'label'
), people as (
  select person, name from clients
  union select person, name from edited_reports
  union select person, name from submitted_counts
)
select coalesce(jsonb_agg(jsonb_build_object(
    'name', p.name,
    'new_clients', coalesce(c.new_clients, 0),
    'existing_clients', coalesce(c.existing_clients, 0),
    'work_items_updated', coalesce(e.work_items_updated, 0),
    'reports_submitted', coalesce(r.reports_submitted, 0),
    'outputs', coalesce((select jsonb_agg(jsonb_build_object('label', o.label, 'count', o.total) order by o.label)
                         from output_counts o where o.person = p.person), '[]'::jsonb)
  ) order by lower(p.name), p.person), '[]'::jsonb)
from people p left join clients c using (person)
left join edited_reports e using (person)
left join submitted_counts r using (person);
$$;
revoke all on function private.ai_summary_staff_activity() from public, anon, authenticated;

create or replace function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' set timezone='Africa/Nairobi' as $$
-- Legacy timestamps without an offset were recorded in Nairobi local time.
with changes_today as (
  select app_key, field, old_value, new_value
  from public.application_changes
  where case when pg_input_is_valid(changed_at, 'timestamp with time zone') then
    changed_at::timestamptz >= private.today()::timestamp at time zone 'Africa/Nairobi'
    and changed_at::timestamptz <= now()
  else false end
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

create or replace function public.ai_summary_claim_job(p_job_token text,p_run_id uuid,p_manual_job uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; secret text; api_key text; job private.ai_summary_jobs; snapshot jsonb;
begin
 select * into c from private.ai_summary_config for update;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null or p_job_token is distinct from secret then raise exception 'invalid_job_token' using errcode='42501'; end if;
 if c.key_id is null then return null; end if;
 select decrypted_secret into api_key from vault.decrypted_secrets where id=c.key_id;
 if api_key is null then return null; end if;
 if p_manual_job is null then
  if not c.enabled or (now() at time zone 'Africa/Nairobi')::time<'17:00'::time then return null; end if;
  if exists(select 1 from private.ai_summary_jobs where status in ('queued','running') and lease_until>now()) then return null; end if;
  -- Manual refreshes never cancel the regular evening report.
  if exists(select 1 from private.ai_summary_jobs where summary_date=private.today()
    and source='scheduled' and status='ready') then return null; end if;
  if (select count(*) from private.ai_summary_jobs where summary_date=private.today() and source='scheduled')>=3 then return null; end if;
  insert into private.ai_summary_jobs(summary_date,source,lease_until,status,run_id)
  values(private.today(),'scheduled',now()+interval '4 minutes','running',p_run_id) returning * into job;
 else
  select * into job from private.ai_summary_jobs where id=p_manual_job for update;
  if job.id is null or job.source<>'manual' or job.status<>'queued' or job.lease_until<=now() then return null; end if;
  -- Recheck the requesting account at execution time.
  if not exists(select 1 from private.app_users where id=job.requested_by and active and role='admin') then
   update private.ai_summary_jobs set status='failed',error_code='admin_required' where id=job.id;
   return null;
  end if;
  if exists(select 1 from private.ai_summary_jobs where id<>job.id and status='running' and lease_until>now()) then return null; end if;
  update private.ai_summary_jobs set status='running',summary_date=private.today(),run_id=p_run_id,lease_until=now()+interval '4 minutes' where id=job.id;
  job.summary_date:=private.today();
 end if;
 snapshot:=private.ai_summary_context();
 update private.ai_summary_jobs set model=c.model,input_snapshot=snapshot,cutoff_at=now() where id=job.id;
 -- Preserve named activity for authorized app readers. The worker receives counts only.
 snapshot:=jsonb_set(snapshot #- '{staff,activity}', '{staff,people_with_recorded_activity}',
   to_jsonb(jsonb_array_length(snapshot->'staff'->'activity')));
 return jsonb_build_object('date',job.summary_date,'model',c.model,'key',api_key,'snapshot',snapshot);
end $$;
