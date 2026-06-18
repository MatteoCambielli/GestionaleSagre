create index order_items_product_id_idx on public.order_items(product_id) where product_id is not null;
create index orders_created_by_idx on public.orders(created_by) where created_by is not null;

alter function public.register_festival(text, text, text, text) set schema private;
alter function public.login_festival(text, text) set schema private;
alter function public.verify_stats_pin(uuid, text) set schema private;
alter function public.create_order(uuid, text, text, jsonb) set schema private;
alter function public.set_order_status(bigint, text) set schema private;
alter function public.complete_kitchen_product(uuid, text, integer) set schema private;

create function public.register_festival(p_name text, p_slug text, p_pin text, p_stats_pin text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.register_festival(p_name, p_slug, p_pin, p_stats_pin) $$;
create function public.login_festival(p_slug text, p_pin text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.login_festival(p_slug, p_pin) $$;
create function public.verify_stats_pin(p_festival_id uuid, p_pin text)
returns boolean language sql volatile security invoker set search_path = ''
as $$ select private.verify_stats_pin(p_festival_id, p_pin) $$;
create function public.create_order(p_festival_id uuid, p_table_number text, p_notes text, p_items jsonb)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select private.create_order(p_festival_id, p_table_number, p_notes, p_items) $$;
create function public.set_order_status(p_order_id bigint, p_status text)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.set_order_status(p_order_id, p_status) $$;
create function public.complete_kitchen_product(p_festival_id uuid, p_product_name text, p_quantity integer)
returns integer language sql volatile security invoker set search_path = ''
as $$ select private.complete_kitchen_product(p_festival_id, p_product_name, p_quantity) $$;

grant execute on function private.register_festival(text, text, text, text) to authenticated;
grant execute on function private.login_festival(text, text) to authenticated;
grant execute on function private.verify_stats_pin(uuid, text) to authenticated;
grant execute on function private.create_order(uuid, text, text, jsonb) to authenticated;
grant execute on function private.set_order_status(bigint, text) to authenticated;
grant execute on function private.complete_kitchen_product(uuid, text, integer) to authenticated;

revoke all on function public.register_festival(text, text, text, text) from public, anon;
revoke all on function public.login_festival(text, text) from public, anon;
revoke all on function public.verify_stats_pin(uuid, text) from public, anon;
revoke all on function public.create_order(uuid, text, text, jsonb) from public, anon;
revoke all on function public.set_order_status(bigint, text) from public, anon;
revoke all on function public.complete_kitchen_product(uuid, text, integer) from public, anon;

grant execute on function public.register_festival(text, text, text, text) to authenticated;
grant execute on function public.login_festival(text, text) to authenticated;
grant execute on function public.verify_stats_pin(uuid, text) to authenticated;
grant execute on function public.create_order(uuid, text, text, jsonb) to authenticated;
grant execute on function public.set_order_status(bigint, text) to authenticated;
grant execute on function public.complete_kitchen_product(uuid, text, integer) to authenticated;
