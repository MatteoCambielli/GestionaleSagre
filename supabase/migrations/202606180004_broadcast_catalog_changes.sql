create or replace function private.broadcast_catalog_change()
returns trigger
language plpgsql volatile security definer set search_path = ''
as $$
declare target_festival uuid := coalesce(new.festival_id, old.festival_id);
begin
  perform private.broadcast_festival_event(
    target_festival, 'db-change',
    jsonb_build_object('entity', tg_table_name, 'operation', tg_op)
  );
  return coalesce(new, old);
end;
$$;

revoke all on function private.broadcast_catalog_change() from public, anon, authenticated;

create trigger categories_broadcast_change
after insert or update or delete on public.categories
for each row execute function private.broadcast_catalog_change();

create trigger products_broadcast_change
after insert or update or delete on public.products
for each row execute function private.broadcast_catalog_change();
