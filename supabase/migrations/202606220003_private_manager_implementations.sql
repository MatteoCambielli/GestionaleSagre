-- Keep privileged implementations outside the Data API schema. Public RPCs are
-- tiny security-invoker wrappers; every private implementation checks admin.
alter function public.manager_dashboard() security invoker;
grant execute on function private.manager_dashboard() to authenticated;

alter function public.manager_list_events() set schema private;
alter function public.manager_get_event(uuid) set schema private;
alter function public.manager_create_event(jsonb) set schema private;
alter function public.manager_update_event(uuid,jsonb) set schema private;
alter function public.manager_event_action(uuid,text,integer) set schema private;
alter function public.manager_reset_event_pins(uuid,text,text) set schema private;
alter function public.release_device_session(uuid,text) set schema private;

create function public.manager_list_events()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.manager_list_events() $$;
create function public.manager_get_event(p_festival_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.manager_get_event(p_festival_id) $$;
create function public.manager_create_event(p_data jsonb)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.manager_create_event(p_data) $$;
create function public.manager_update_event(p_festival_id uuid,p_data jsonb)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.manager_update_event(p_festival_id,p_data) $$;
create function public.manager_event_action(p_festival_id uuid,p_action text,p_value integer default null)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.manager_event_action(p_festival_id,p_action,p_value) $$;
create function public.manager_reset_event_pins(p_festival_id uuid,p_operational_pin text,p_stats_pin text)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.manager_reset_event_pins(p_festival_id,p_operational_pin,p_stats_pin) $$;
create function public.release_device_session(p_festival_id uuid,p_device_id text)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.release_device_session(p_festival_id,p_device_id) $$;

revoke all on function private.manager_list_events() from public,anon;
revoke all on function private.manager_get_event(uuid) from public,anon;
revoke all on function private.manager_create_event(jsonb) from public,anon;
revoke all on function private.manager_update_event(uuid,jsonb) from public,anon;
revoke all on function private.manager_event_action(uuid,text,integer) from public,anon;
revoke all on function private.manager_reset_event_pins(uuid,text,text) from public,anon;
revoke all on function private.release_device_session(uuid,text) from public,anon;
grant execute on function private.manager_list_events() to authenticated;
grant execute on function private.manager_get_event(uuid) to authenticated;
grant execute on function private.manager_create_event(jsonb) to authenticated;
grant execute on function private.manager_update_event(uuid,jsonb) to authenticated;
grant execute on function private.manager_event_action(uuid,text,integer) to authenticated;
grant execute on function private.manager_reset_event_pins(uuid,text,text) to authenticated;
grant execute on function private.release_device_session(uuid,text) to authenticated;

revoke all on function public.manager_list_events() from public,anon;
revoke all on function public.manager_get_event(uuid) from public,anon;
revoke all on function public.manager_create_event(jsonb) from public,anon;
revoke all on function public.manager_update_event(uuid,jsonb) from public,anon;
revoke all on function public.manager_event_action(uuid,text,integer) from public,anon;
revoke all on function public.manager_reset_event_pins(uuid,text,text) from public,anon;
revoke all on function public.release_device_session(uuid,text) from public,anon;
grant execute on function public.manager_list_events() to authenticated;
grant execute on function public.manager_get_event(uuid) to authenticated;
grant execute on function public.manager_create_event(jsonb) to authenticated;
grant execute on function public.manager_update_event(uuid,jsonb) to authenticated;
grant execute on function public.manager_event_action(uuid,text,integer) to authenticated;
grant execute on function public.manager_reset_event_pins(uuid,text,text) to authenticated;
grant execute on function public.release_device_session(uuid,text) to authenticated;

-- The privileged RPCs bypass RLS only after their role checks, so direct manager
-- write policies are unnecessary. Keeping one SELECT policy avoids duplicate work.
drop policy if exists "admins manage profiles" on public.profiles;
drop policy if exists "admins manage clients" on public.clients;
drop policy if exists "admins manage licenses" on public.event_licenses;
drop policy if exists "admins manage sessions" on public.active_sessions;

create index if not exists audit_actor_user_idx
on public.license_audit_logs(actor_user_id) where actor_user_id is not null;
