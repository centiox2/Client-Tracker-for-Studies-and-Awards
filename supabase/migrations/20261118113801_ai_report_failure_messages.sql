-- Use the lightweight model verified with this project's key. Other explicit model choices are kept.
alter table private.ai_summary_config alter column model set default 'gemini-3.5-flash-lite';
update private.ai_summary_config set model='gemini-3.5-flash-lite' where id=true and model='gemini-3.8-flash';
-- Return safe, actionable failure text; never return raw provider errors or credentials.
create or replace function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; job private.ai_summary_jobs; state text; failure text;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select * into job from private.ai_summary_jobs where summary_date=private.today()
  or (status in ('queued','running') and lease_until>now())
 order by (status in ('queued','running') and lease_until>now()) desc,created_at desc,id desc limit 1;
 state:=case when job.status in ('queued','running') and job.lease_until<=now() then 'failed' else job.status end;
 if state is null then select status into state from private.ai_summaries where summary_date=private.today(); end if;
 failure:=case
  when job.error_code in ('gemini_http_503','gemini_http_500','gemini_http_502','gemini_http_504','gemini_temporarily_unavailable') then 'Gemini is temporarily busy. Please try generating the report again shortly.'
  when job.error_code in ('gemini_http_429','gemini_quota_exceeded') then 'Gemini quota or rate limit reached. Check your Google AI Studio usage and try again later.'
  when job.error_code in ('gemini_http_401','gemini_http_403','gemini_key_rejected') then 'Gemini rejected access. Admin should check the API key and its project permissions in Settings.'
  when job.error_code in ('gemini_http_404','gemini_model_unavailable') then 'The selected Gemini model is unavailable for this key. Admin can choose an available model in Settings.'
  when job.error_code='gemini_timeout' or (job.status in ('queued','running') and job.lease_until<=now()) then 'The report request timed out. Please try generating it again.'
  when job.error_code='gemini_request_invalid' then 'Gemini could not accept the report request. Check the selected model or contact Admin.'
  when job.error_code in ('gemini_incomplete','gemini_invalid_report') then 'Gemini returned an incomplete report. Please try generating it again.'
  else 'The report could not be generated. Please try again or contact Admin.' end;
 select jsonb_build_object('error_message',case when state='failed' then failure else null end,'enabled',c.enabled,'configured',c.key_id is not null,
  'can_generate',private.token_role(p_token)='admin','today',private.today(),'status',coalesce(state,'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,input_snapshot from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;
