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
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*)) from public.staff));
$$;
