-- ===== Profile password versions (2026-11-04) =====
-- When each profile's password last changed, so a device where someone
-- chose "Keep me signed in" asks again after the admin changes it.
create or replace function public.profile_versions()
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(role, updated_at::text), '{}'::jsonb)
  from private.profile_secret;
$$;
revoke all on function public.profile_versions() from public;
grant execute on function public.profile_versions() to anon, authenticated;
