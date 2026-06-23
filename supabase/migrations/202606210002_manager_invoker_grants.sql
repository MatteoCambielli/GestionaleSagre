-- Manager RPCs are security-invoker: table grants let them run, while RLS still
-- restricts every row to the platform administrator.
grant select on
  public.profiles,
  public.clients,
  public.event_licenses,
  public.active_sessions,
  public.license_audit_logs
to authenticated;
