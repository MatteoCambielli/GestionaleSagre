-- Security hardening for manager credentials and PIN recovery.
alter table private.login_throttles enable row level security;

create or replace function private.revoke_anonymous_event_access(p_festival_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $$
begin
  delete from public.active_sessions where festival_id = p_festival_id;
  delete from public.festival_members membership
  using auth.users account
  where membership.festival_id = p_festival_id
    and membership.user_id = account.id
    and account.is_anonymous = true;
end;
$$;

revoke all on function private.revoke_anonymous_event_access(uuid) from public, anon, authenticated;

create or replace function public.manager_reset_event_pins(
  p_festival_id uuid,
  p_operational_pin text,
  p_stats_pin text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare target_slug text;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  if p_operational_pin !~ '^[0-9]{4,12}$'
    or p_stats_pin !~ '^[0-9]{4,12}$'
    or p_operational_pin = p_stats_pin then
    raise exception 'I PIN devono contenere 4-12 cifre ed essere diversi';
  end if;

  update public.festivals
  set pin_hash = extensions.crypt(p_operational_pin, extensions.gen_salt('bf', 11)),
      stats_pin_hash = extensions.crypt(p_stats_pin, extensions.gen_salt('bf', 11))
  where id = p_festival_id
  returning slug into target_slug;
  if target_slug is null then raise exception 'event not found'; end if;

  delete from private.login_throttles where festival_slug = target_slug;
  perform private.revoke_anonymous_event_access(p_festival_id);
  insert into public.license_audit_logs(festival_id, actor_user_id, action)
  values (p_festival_id, auth.uid(), 'credentials_reset');
  perform private.broadcast_festival_event(
    p_festival_id, 'credentials-changed', jsonb_build_object('pin_type', 'all')
  );
end;
$$;

revoke all on function public.manager_reset_event_pins(uuid,text,text) from public, anon;
grant execute on function public.manager_reset_event_pins(uuid,text,text) to authenticated;

create or replace function private.reset_festival_pin(
  p_festival_id uuid,
  p_pin_type text,
  p_new_pin text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare target_slug text;
begin
  if auth.uid() is null
    or coalesce((auth.jwt()->>'is_anonymous')::boolean, true)
    or p_pin_type not in ('operational', 'stats')
    or p_new_pin !~ '^[0-9]{4,12}$' then
    raise exception 'invalid recovery request';
  end if;
  if not exists (
    select 1 from public.festival_members
    where festival_id = p_festival_id and user_id = auth.uid() and role = 'owner'
  ) then raise exception 'owner access required'; end if;

  if p_pin_type = 'operational' then
    update public.festivals
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 11))
    where id = p_festival_id returning slug into target_slug;
    perform private.revoke_anonymous_event_access(p_festival_id);
  else
    update public.festivals
    set stats_pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 11))
    where id = p_festival_id returning slug into target_slug;
  end if;

  delete from private.login_throttles where festival_slug = target_slug;
  perform private.broadcast_festival_event(
    p_festival_id, 'credentials-changed', jsonb_build_object('pin_type', p_pin_type)
  );
end;
$$;

revoke all on function private.reset_festival_pin(uuid,text,text) from public, anon;
grant execute on function private.reset_festival_pin(uuid,text,text) to authenticated;
