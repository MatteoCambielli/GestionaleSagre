create or replace function public.get_owned_festivals()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', festival.id,
        'name', festival.name,
        'slug', festival.slug,
        'created_at', festival.created_at
      ) order by festival.created_at desc
    ),
    '[]'::jsonb
  )
  from public.festival_members as membership
  join public.festivals as festival on festival.id = membership.festival_id
  where membership.user_id = (select auth.uid())
    and membership.role = 'owner'
    and coalesce(((select auth.jwt())->>'is_anonymous')::boolean, true) = false;
$$;

create or replace function private.reset_festival_pin(
  p_festival_id uuid,
  p_pin_type text,
  p_new_pin text
)
returns void
language plpgsql volatile security definer set search_path = ''
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
    where festival_id = p_festival_id
      and user_id = auth.uid()
      and role = 'owner'
  ) then
    raise exception 'owner access required';
  end if;

  if p_pin_type = 'operational' then
    update public.festivals
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 11))
    where id = p_festival_id
    returning slug into target_slug;
  else
    update public.festivals
    set stats_pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 11))
    where id = p_festival_id
    returning slug into target_slug;
  end if;

  delete from private.login_throttles as throttle where throttle.festival_slug = target_slug;
  perform private.broadcast_festival_event(
    p_festival_id, 'credentials-changed',
    jsonb_build_object('pin_type', p_pin_type)
  );
end;
$$;

create or replace function public.reset_festival_pin(
  p_festival_id uuid,
  p_pin_type text,
  p_new_pin text
)
returns void
language sql volatile security invoker set search_path = ''
as $$ select private.reset_festival_pin(p_festival_id, p_pin_type, p_new_pin) $$;

revoke all on function private.reset_festival_pin(uuid, text, text) from public, anon;
grant execute on function private.reset_festival_pin(uuid, text, text) to authenticated;

revoke all on function public.get_owned_festivals() from public, anon;
revoke all on function public.reset_festival_pin(uuid, text, text) from public, anon;
grant execute on function public.get_owned_festivals() to authenticated;
grant execute on function public.reset_festival_pin(uuid, text, text) to authenticated;
