-- Generation jobs are separate from published reports, so refresh failures never
-- hide or destroy the last successful report. Clients only request jobs via RPC.
create table private.ai_summary_jobs (
 id uuid primary key default gen_random_uuid(), summary_date date not null,
 source text not null check(source in ('manual','scheduled')),
 requested_by bigint references private.app_users(id) on delete set null,
 created_at timestamptz not null default now(), lease_until timestamptz not null,
 status text not null check(status in ('queued','running','ready','failed')),
 run_id uuid unique, cutoff_at timestamptz, model text, input_snapshot jsonb, error_code text
);
create index ai_summary_jobs_date_idx on private.ai_summary_jobs(summary_date,created_at desc);
create index ai_summary_jobs_requested_by_idx on private.ai_summary_jobs(requested_by);
create index ai_summary_jobs_active_idx on private.ai_summary_jobs(lease_until) where status in ('queued','running');
alter table private.ai_summary_jobs enable row level security;
revoke all on private.ai_summary_jobs from public,anon,authenticated;
-- Preserve successful reports produced by the earlier scheduled-only worker.
insert into private.ai_summary_jobs(summary_date,source,created_at,lease_until,status,run_id,cutoff_at,model,input_snapshot)
select summary_date,'scheduled',coalesce(generated_at,cutoff_at),lease_until,'ready',run_id,cutoff_at,model,input_snapshot
from private.ai_summaries where status='ready';


create function public.ai_summary_generate(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; job uuid; secret text;
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 select * into c from private.ai_summary_config for update;
 if c.key_id is null then raise exception 'gemini_key_required'; end if;
 select id into job from private.ai_summary_jobs where status in ('queued','running') and lease_until>now() limit 1;
 if job is not null then return jsonb_build_object('status','running','job_id',job); end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null then raise exception 'job_not_configured'; end if;
 if not exists(select 1 from vault.decrypted_secrets where id=c.key_id) then raise exception 'gemini_key_required'; end if;
 insert into private.ai_summary_jobs(summary_date,source,requested_by,lease_until,status)
 values(private.today(),'manual',private.token_user(p_token),now()+interval '4 minutes','queued') returning id into job;
 perform net.http_post(url:='https://dpmluuckgstycdctqwym.supabase.co/functions/v1/daily-ai-summary',
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),
 body:=jsonb_build_object('manual_job_id',job),timeout_milliseconds:=180000);
 return jsonb_build_object('status','queued','job_id',job);
end $$;

create function public.ai_summary_claim_job(p_job_token text,p_run_id uuid,p_manual_job uuid default null) returns jsonb
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
 return jsonb_build_object('date',job.summary_date,'model',c.model,'key',api_key,'snapshot',snapshot);
end $$;
-- Keep the scheduler RPC compatible with existing worker deployments.
create or replace function public.ai_summary_claim(p_job_token text,p_run_id uuid) returns jsonb
language sql security definer set search_path='' as $$
 select public.ai_summary_claim_job(p_job_token,p_run_id,null);
$$;
create or replace function public.ai_summary_finish(p_run_id uuid,p_content jsonb default null,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job private.ai_summary_jobs;
begin
 if p_content is not null and (jsonb_typeof(p_content)<>'object' or length(p_content::text)>40000) then raise exception 'invalid_summary'; end if;
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
create or replace function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; job private.ai_summary_jobs; state text;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select * into job from private.ai_summary_jobs where summary_date=private.today()
  or (status in ('queued','running') and lease_until>now())
 order by (status in ('queued','running') and lease_until>now()) desc,created_at desc,id desc limit 1;
 state:=case when job.status in ('queued','running') and job.lease_until<=now() then 'failed' else job.status end;
 if state is null then select status into state from private.ai_summaries where summary_date=private.today(); end if;
 select jsonb_build_object('enabled',c.enabled,'configured',c.key_id is not null,
  'can_generate',private.token_role(p_token)='admin','today',private.today(),'status',coalesce(state,'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;
revoke all on function public.ai_summary_generate(text) from public;
grant execute on function public.ai_summary_generate(text) to anon,authenticated;
revoke all on function public.ai_summary_claim_job(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.ai_summary_claim_job(text,uuid,uuid) to service_role;
