-- Private, explicitly assigned company-wide daily summaries. No key is returned to apps.
create extension if not exists pg_net with schema extensions;
create table private.ai_summary_config (
 id boolean primary key default true check(id), enabled boolean not null default false,
 model text not null default 'gemini-3.8-flash', key_id uuid, job_key_id uuid not null
);
insert into private.ai_summary_config(job_key_id)
 values(vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'ai_summary_job_token'));
create table private.ai_summary_access (
 user_id bigint primary key references private.app_users(id) on delete cascade
);
create table private.ai_summaries (
 summary_date date primary key, status text not null check(status in ('running','ready','failed')),
 run_id uuid not null, attempts integer not null default 1, lease_until timestamptz not null,
 cutoff_at timestamptz not null, generated_at timestamptz, model text not null,
 content jsonb, input_snapshot jsonb not null, error_code text
);
alter table private.ai_summary_config enable row level security;
alter table private.ai_summary_access enable row level security;
alter table private.ai_summaries enable row level security;
revoke all on private.ai_summary_config, private.ai_summary_access, private.ai_summaries from public,anon,authenticated;

create function public.ai_summary_access(p_token text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if private.token_role(p_token) = 'admin' then return true; end if;
 return exists(select 1 from private.ai_summary_access where user_id=private.token_user(p_token));
end $$;
create function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,
  'today',private.today(),
  'status',coalesce((select status from private.ai_summaries where summary_date=private.today()),'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result
 from private.ai_summary_config c;
 return result;
end $$;
create function public.ai_summary_settings(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 return (select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,'model',c.model,
  'users',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(u.full_name,''),u.username),
  'role',u.role,'assigned',a.user_id is not null) order by u.username)
  from private.app_users u left join private.ai_summary_access a on a.user_id=u.id where u.active),'[]'::jsonb))
  from private.ai_summary_config c);
end $$;
create function public.ai_summary_configure(p_token text,p_enabled boolean,p_model text,p_user_ids bigint[],p_key text default null)
returns void language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config;
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 if p_model is null or p_model !~ '^gemini-[a-zA-Z0-9.-]{1,80}$' then raise exception 'invalid_model'; end if;
 select * into c from private.ai_summary_config for update;
 if nullif(trim(p_key),'') is not null then
  if length(p_key)<20 or length(p_key)>512 then raise exception 'invalid_key'; end if;
  if c.key_id is null then c.key_id:=vault.create_secret(trim(p_key),'ai_summary_gemini_key');
  else perform vault.update_secret(c.key_id,trim(p_key)); end if;
 end if;
 if p_enabled and c.key_id is null then raise exception 'gemini_key_required'; end if;
 update private.ai_summary_config set enabled=p_enabled, model=p_model,key_id=c.key_id where id=true;
 delete from private.ai_summary_access where user_id is not null;
 insert into private.ai_summary_access(user_id) select id from private.app_users
 where active and id=any(coalesce(p_user_ids,'{}'::bigint[]));
end $$;

-- Only aggregate data goes to the model. Personal to-do text, student names,
-- credentials, report descriptions and individual revenue notes are excluded.
create function private.ai_summary_context() returns jsonb
language sql security definer set search_path='' as $$
select jsonb_build_object('date',private.today(),'timezone','Africa/Nairobi','cutoff_at',now(),
 'weekly_tracker',(select jsonb_build_object('today',coalesce(sum(c.new_clients+c.existing_clients) filter(where d.date=private.today()::text),0),
 'month_new',coalesce(sum(c.new_clients),0),'month_existing',coalesce(sum(c.existing_clients),0))
 from public.client_counts c join public.work_days d on d.id=c.day_id
 where d.date>=date_trunc('month',private.today())::date::text and d.date<=private.today()::text
 and not exists(select 1 from public.staff_day_off o where o.day_id=c.day_id and o.staff_id=c.staff_id)),
 'revenue',(select jsonb_build_object('currency',coalesce((select value from public.app_settings where key='currency'),'unspecified'),'today_cents',coalesce(sum(amount_cents) filter(where date=private.today()::text),0),
 'month_net_cents',coalesce(sum(amount_cents),0)) from public.revenue_entries
 where date>=date_trunc('month',private.today())::date::text and date<=private.today()::text),
 'applications',(select jsonb_build_object('total',count(*),'with_offer',count(*) filter(where nullif(offer_date,'') is not null),
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
 'staff',(select jsonb_build_object('active',count(*) filter(where active=1),'total',count(*)) from public.staff),
 'history',(select jsonb_build_object('recorded_weeks',count(*)) from public.weeks),
 'reports','Client performance uses recorded counts; missing entries cannot be assumed to mean no activity.',
 'settings','Summary scheduled at 17:05 Africa/Nairobi. Personal preferences are not included.');
$$;
create function public.ai_summary_claim(p_job_token text,p_run_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; secret text; snapshot jsonb; accepted date;
begin
 select * into c from private.ai_summary_config for update;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if p_job_token is null or p_job_token<>secret then raise exception 'invalid_job_token' using errcode='42501'; end if;
 if not c.enabled or c.key_id is null or (now() at time zone 'Africa/Nairobi')::time<'17:00'::time then return null; end if;
 snapshot:=private.ai_summary_context();
 insert into private.ai_summaries(summary_date,status,run_id,lease_until,cutoff_at,model,input_snapshot)
 values(private.today(),'running',p_run_id,now()+interval '4 minutes',now(),c.model,snapshot)
 on conflict(summary_date) do update set status='running',run_id=excluded.run_id,
 attempts=private.ai_summaries.attempts+1,lease_until=excluded.lease_until,cutoff_at=excluded.cutoff_at,
 model=excluded.model,input_snapshot=excluded.input_snapshot,error_code=null
 where private.ai_summaries.status<>'ready' and private.ai_summaries.lease_until<now() and private.ai_summaries.attempts<3
 returning summary_date into accepted;
 if accepted is null then return null; end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.key_id;
 return jsonb_build_object('date',accepted,'model',c.model,'key',secret,'snapshot',snapshot);
end $$;
create function public.ai_summary_finish(p_run_id uuid,p_content jsonb default null,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_content is not null and (jsonb_typeof(p_content)<>'object' or length(p_content::text)>40000) then raise exception 'invalid_summary'; end if;
 update private.ai_summaries set status=case when p_content is null then 'failed' else 'ready' end,
 content=p_content,generated_at=case when p_content is null then null else now() end,
 error_code=case when p_content is null then left(coalesce(p_error,'generation_failed'),80) else null end
 where run_id=p_run_id and status='running' and lease_until>now();
end $$;
create function private.ai_summary_dispatch() returns void
language plpgsql security definer set search_path='' as $$
declare secret text;
begin
 if not exists(select 1 from private.ai_summary_config where enabled and key_id is not null) then return; end if;
 select v.decrypted_secret into secret from private.ai_summary_config c join vault.decrypted_secrets v on v.id=c.job_key_id;
 perform net.http_post(url:='https://dpmluuckgstycdctqwym.supabase.co/functions/v1/daily-ai-summary',
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),body:='{}'::jsonb,timeout_milliseconds:=180000);
end $$;
revoke all on function private.ai_summary_context(),private.ai_summary_dispatch() from public,anon,authenticated;
revoke all on function public.ai_summary_claim(text,uuid),public.ai_summary_finish(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.ai_summary_claim(text,uuid),public.ai_summary_finish(uuid,jsonb,text) to service_role;
revoke all on function public.ai_summary_access(text),public.ai_summary_read(text),public.ai_summary_settings(text),public.ai_summary_configure(text,boolean,text,bigint[],text) from public;
grant execute on function public.ai_summary_access(text),public.ai_summary_read(text),public.ai_summary_settings(text),public.ai_summary_configure(text,boolean,text,bigint[],text) to anon,authenticated;
select cron.schedule('daily-ai-summary','5,15,25 14 * * *','select private.ai_summary_dispatch()');
