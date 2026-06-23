create or replace function public.manager_list_events()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
declare result jsonb;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  select private.manager_list_events() into result;
  return result;
end;
$$;

revoke all on function public.manager_list_events() from public,anon;
grant execute on function public.manager_list_events() to authenticated;
