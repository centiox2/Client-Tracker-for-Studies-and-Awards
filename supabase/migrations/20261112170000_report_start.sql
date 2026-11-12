-- Daily reports open in one round trip: who you are, the departments and
-- people you see, and your own day (today's reports, everything still open
-- and this week so far), instead of a call for the page and then three
-- more for the lists.
create or replace function public.report_start(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_today date := private.today();
  v_monday date := v_today - (extract(isodow from v_today)::int - 1);
begin
  return jsonb_build_object(
    'meta', public.reports_meta(p_token),
    'day', public.report_list(p_token, jsonb_build_object(
      'from', v_today, 'to', v_today, 'user_id', me)),
    'open', public.report_list(p_token, jsonb_build_object(
      'user_id', me, 'open_only', true)),
    'week', public.report_list(p_token, jsonb_build_object(
      'from', v_monday, 'to', v_today, 'user_id', me))
  );
end $$;

revoke all on function public.report_start(text) from public;
grant execute on function public.report_start(text) to anon, authenticated;
