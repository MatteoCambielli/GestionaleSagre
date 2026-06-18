alter table public.festivals
  add column stats_pin_hash text;

update public.festivals
set stats_pin_hash = crypt('9999', gen_salt('bf'))
where stats_pin_hash is null;

alter table public.festivals
  alter column stats_pin_hash set not null;

alter table public.order_items
  add column prepared_quantity integer not null default 0
  check (prepared_quantity >= 0 and prepared_quantity <= quantity);

drop function if exists public.register_festival(text, text, text);

create or replace function public.register_festival(p_name text, p_slug text, p_pin text, p_stats_pin text)
returns public.festivals
language plpgsql security definer set search_path = '' as $$
declare created public.festivals;
begin
  if auth.uid() is null or char_length(p_pin) < 4 or char_length(p_stats_pin) < 4 then
    raise exception 'invalid registration';
  end if;
  insert into public.festivals(name, slug, pin_hash, stats_pin_hash)
  values (
    trim(p_name), lower(trim(p_slug)), crypt(p_pin, gen_salt('bf')),
    crypt(p_stats_pin, gen_salt('bf'))
  ) returning * into created;
  insert into public.festival_members(festival_id, user_id) values (created.id, auth.uid());
  insert into public.categories(festival_id, name, sort_order)
  values (created.id, 'Cucina', 0), (created.id, 'Bere', 1);
  return created;
end $$;

create or replace function public.verify_stats_pin(p_festival_id uuid, p_pin text)
returns boolean
language sql stable security invoker set search_path = '' as $$
  select exists (
    select 1 from public.festivals
    where id = p_festival_id
      and public.is_festival_member(id)
      and stats_pin_hash = crypt(p_pin, stats_pin_hash)
  );
$$;

create or replace function public.complete_kitchen_product(p_festival_id uuid, p_product_name text)
returns void
language plpgsql security invoker set search_path = '' as $$
begin
  if not public.is_festival_member(p_festival_id) then
    raise exception 'access denied';
  end if;

  update public.order_items
  set prepared_quantity = quantity
  where festival_id = p_festival_id
    and lower(name) = lower(p_product_name)
    and category not in ('Bere', 'Bevande')
    and prepared_quantity < quantity;

  update public.orders as target
  set kitchen_done = true
  where target.festival_id = p_festival_id
    and target.kitchen_done = false
    and not exists (
      select 1 from public.order_items as item
      where item.order_id = target.id
        and item.category not in ('Bere', 'Bevande')
        and item.prepared_quantity < item.quantity
    );
end $$;

revoke all on function public.register_festival(text, text, text, text) from public, anon;
revoke all on function public.verify_stats_pin(uuid, text) from public, anon;
revoke all on function public.complete_kitchen_product(uuid, text) from public, anon;
grant execute on function public.register_festival(text, text, text, text) to authenticated;
grant execute on function public.verify_stats_pin(uuid, text) to authenticated;
grant execute on function public.complete_kitchen_product(uuid, text) to authenticated;
