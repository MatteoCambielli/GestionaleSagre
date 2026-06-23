-- Privileged manager mutations stay behind role-checking RPCs. The browser gets
-- no direct write privilege on commercial or identity tables.
alter function public.manager_dashboard() security definer;
alter function public.manager_list_events() security definer;
alter function public.manager_get_event(uuid) security definer;
alter function public.manager_create_event(jsonb) security definer;
alter function public.manager_update_event(uuid, jsonb) security definer;
alter function public.manager_event_action(uuid, text, integer) security definer;
alter function public.release_device_session(uuid, text) security definer;

revoke insert, update, delete on
  public.profiles,
  public.clients,
  public.event_licenses,
  public.active_sessions,
  public.license_audit_logs
from authenticated;
