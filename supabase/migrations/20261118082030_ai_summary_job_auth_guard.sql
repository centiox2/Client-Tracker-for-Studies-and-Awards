-- Fail closed if the scheduled job secret has been removed from Vault.
create or replace function public.ai_summary_claim(p_job_token text,p_run_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; secret text; snapshot jsonb; accepted date;
begin
 select * into c from private.ai_summary_config for update;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null or p_job_token is distinct from secret then raise exception 'invalid_job_token' using errcode='42501'; end if;
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
