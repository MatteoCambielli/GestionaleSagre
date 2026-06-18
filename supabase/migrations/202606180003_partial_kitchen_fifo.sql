drop function if exists public.complete_kitchen_product(uuid, text);

create or replace function public.complete_kitchen_product(
  p_festival_id uuid,
  p_product_name text,
  p_quantity integer
)
returns integer
language plpgsql security invoker set search_path = '' as $$
declare
  target record;
  remaining integer := greatest(coalesce(p_quantity, 0), 0);
  prepared_now integer;
  prepared_total integer := 0;
begin
  if not public.is_festival_member(p_festival_id) then
    raise exception 'access denied';
  end if;

  if remaining = 0 then
    return 0;
  end if;

  for target in
    select item.id, item.quantity, item.prepared_quantity
    from public.order_items as item
    join public.orders as customer_order on customer_order.id = item.order_id
    where item.festival_id = p_festival_id
      and lower(item.name) = lower(p_product_name)
      and item.category not in ('Bere', 'Bevande')
      and item.prepared_quantity < item.quantity
    order by customer_order.created_at asc, customer_order.id asc, item.id asc
    for update of item
  loop
    exit when remaining = 0;
    prepared_now := least(target.quantity - target.prepared_quantity, remaining);

    update public.order_items
    set prepared_quantity = prepared_quantity + prepared_now
    where id = target.id;

    remaining := remaining - prepared_now;
    prepared_total := prepared_total + prepared_now;
  end loop;

  update public.orders as customer_order
  set kitchen_done = true
  where customer_order.festival_id = p_festival_id
    and customer_order.kitchen_done = false
    and not exists (
      select 1
      from public.order_items as item
      where item.order_id = customer_order.id
        and item.category not in ('Bere', 'Bevande')
        and item.prepared_quantity < item.quantity
    );

  return prepared_total;
end $$;

revoke all on function public.complete_kitchen_product(uuid, text, integer) from public, anon;
grant execute on function public.complete_kitchen_product(uuid, text, integer) to authenticated;
