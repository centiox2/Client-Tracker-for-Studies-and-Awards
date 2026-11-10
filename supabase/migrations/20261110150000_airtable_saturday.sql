-- Saturdays: Airtable is read once an hour (08:00 to 18:00 Kenya time)
-- instead of every 30 minutes, to save API calls. Monday to Friday stays
-- every 30 minutes; the nightly full read is unchanged.
do $$
begin
  perform cron.unschedule(jobname) from cron.job
    where jobname in ('airtable-changes', 'airtable-saturday');
  perform cron.schedule('airtable-changes', '*/30 5-15 * * 1-5',
    $job$select private.airtable_scheduled('changes')$job$);
  perform cron.schedule('airtable-saturday', '0 5-15 * * 6',
    $job$select private.airtable_scheduled('changes')$job$);
end $$;
