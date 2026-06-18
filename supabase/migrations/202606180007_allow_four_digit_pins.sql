create or replace function private.register_festival(
  p_name text,
  p_slug text,
  p_pin text,
  p_stats_pin text
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  created public.festivals;
begin
  if auth.uid() is null
    or char_length(trim(p_name)) not between 2 and 80
    or lower(trim(p_slug)) !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    or p_pin !~ '^[0-9]{4,12}$'
    or p_stats_pin !~ '^[0-9]{4,12}$'
    or p_pin = p_stats_pin then
    return jsonb_build_object('ok', false, 'error', 'Dati o PIN non validi');
  end if;

  if (select count(*) from public.festival_members where user_id = auth.uid() and role = 'owner') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Limite attività raggiunto');
  end if;

  insert into public.festivals(name, slug, pin_hash, stats_pin_hash)
  values (
    trim(p_name), lower(trim(p_slug)),
    extensions.crypt(p_pin, extensions.gen_salt('bf', 11)),
    extensions.crypt(p_stats_pin, extensions.gen_salt('bf', 11))
  )
  returning * into created;

  insert into public.festival_members(festival_id, user_id, role, stats_access_until)
  values (created.id, auth.uid(), 'owner', 'infinity');

  insert into public.categories(festival_id, name, sort_order)
  values (created.id, 'Cucina', 0), (created.id, 'Bere', 1);

  return jsonb_build_object(
    'ok', true,
    'festival', jsonb_build_object('id', created.id, 'name', created.name, 'slug', created.slug)
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'Codice attività già utilizzato');
end;
$$;
