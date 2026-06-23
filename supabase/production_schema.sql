-- Ordiva - production schema for a fresh Supabase project.
-- Run this file once in the Supabase SQL Editor.

begin;

create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

revoke all on schema private from public, anon, authenticated;

-- Remove accidental RPC access to Supabase's optional RLS event-trigger helper.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke all on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;

create table public.festivals (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  timezone text not null default 'Europe/Rome',
  pin_hash text not null,
  stats_pin_hash text not null,
  created_at timestamptz not null default now()
);

create table public.festival_members (
  festival_id uuid not null references public.festivals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'operator' check (role in ('owner', 'manager', 'operator')),
  stats_access_until timestamptz,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (festival_id, user_id)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  festival_id uuid not null references public.festivals(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  sort_order smallint not null default 0,
  created_at timestamptz not null default now(),
  unique (festival_id, name)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  festival_id uuid not null references public.festivals(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 100),
  price numeric(10,2) not null check (price >= 0 and price <= 99999.99),
  category text not null check (char_length(category) between 1 and 60),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (festival_id, name)
);

create table public.orders (
  id bigint generated always as identity primary key,
  festival_id uuid not null references public.festivals(id) on delete cascade,
  service_date date not null,
  table_number text not null check (char_length(table_number) between 1 and 20),
  notes text not null default '' check (char_length(notes) <= 500),
  total numeric(10,2) not null check (total >= 0),
  paid boolean not null default false,
  kitchen_done boolean not null default false,
  bar_done boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  kitchen_done_at timestamptz,
  bar_done_at timestamptz
);

create table public.order_items (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  festival_id uuid not null references public.festivals(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null check (char_length(name) between 1 and 100),
  price numeric(10,2) not null check (price >= 0),
  quantity smallint not null check (quantity between 1 and 999),
  prepared_quantity smallint not null default 0,
  category text not null check (char_length(category) between 1 and 60),
  constraint order_items_prepared_quantity_check
    check (prepared_quantity between 0 and quantity)
);

create table private.login_throttles (
  user_id uuid not null,
  festival_slug text not null,
  failures smallint not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, festival_slug)
);

-- Tenant, queue, history, join and RLS indexes.
create index festival_members_user_idx on public.festival_members(user_id, festival_id);
create index categories_festival_sort_idx on public.categories(festival_id, sort_order, id);
create index products_festival_active_name_idx on public.products(festival_id, active, name);
create index orders_festival_history_idx on public.orders(festival_id, service_date desc, created_at desc, id desc);
create index orders_festival_created_idx on public.orders(festival_id, created_at, id);
create index orders_open_kitchen_idx on public.orders(festival_id, created_at, id) where kitchen_done = false;
create index orders_open_bar_idx on public.orders(festival_id, created_at, id) where bar_done = false;
create index orders_unpaid_idx on public.orders(festival_id, created_at, id) where paid = false;
create index order_items_order_idx on public.order_items(order_id, id);
create index order_items_festival_product_idx on public.order_items(festival_id, product_id);
create index order_items_product_id_idx on public.order_items(product_id) where product_id is not null;
create index orders_created_by_idx on public.orders(created_by) where created_by is not null;

alter table public.festivals enable row level security;
alter table public.festival_members enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create or replace function private.is_festival_member(target_festival uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.festival_members
    where festival_id = target_festival
      and user_id = (select auth.uid())
  );
$$;

create or replace function private.is_festival_admin(target_festival uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.festival_members
    where festival_id = target_festival
      and user_id = (select auth.uid())
      and role in ('owner', 'manager')
  );
$$;

create or replace function private.has_stats_access(target_festival uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.festival_members
    where festival_id = target_festival
      and user_id = (select auth.uid())
      and (role in ('owner', 'manager') or stats_access_until > now())
  );
$$;

create or replace function private.can_receive_festival_broadcast(target_topic text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.festival_members
    where user_id = (select auth.uid())
      and ('festival:' || festival_id::text) = target_topic
  );
$$;

create or replace function private.broadcast_festival_event(
  target_festival uuid,
  event_name text,
  event_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  perform realtime.send(
    event_payload || jsonb_build_object('festival_id', target_festival),
    event_name,
    'festival:' || target_festival::text,
    true
  );
end;
$$;

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

create trigger categories_broadcast_change
after insert or update or delete on public.categories
for each row execute function private.broadcast_catalog_change();

create trigger products_broadcast_change
after insert or update or delete on public.products
for each row execute function private.broadcast_catalog_change();

revoke all on function private.is_festival_member(uuid) from public, anon;
revoke all on function private.is_festival_admin(uuid) from public, anon;
revoke all on function private.has_stats_access(uuid) from public, anon;
revoke all on function private.can_receive_festival_broadcast(text) from public, anon;
revoke all on function private.broadcast_festival_event(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function private.broadcast_catalog_change() from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.is_festival_member(uuid) to authenticated;
grant execute on function private.is_festival_admin(uuid) to authenticated;
grant execute on function private.has_stats_access(uuid) to authenticated;
grant execute on function private.can_receive_festival_broadcast(text) to authenticated;

create policy "members read festivals"
on public.festivals for select to authenticated
using ((select private.is_festival_member(id)));

create policy "members read own membership"
on public.festival_members for select to authenticated
using (user_id = (select auth.uid()));

create policy "members read categories"
on public.categories for select to authenticated
using ((select private.is_festival_member(festival_id)));
create policy "admins insert categories"
on public.categories for insert to authenticated
with check ((select private.is_festival_admin(festival_id)));
create policy "admins update categories"
on public.categories for update to authenticated
using ((select private.is_festival_admin(festival_id)))
with check ((select private.is_festival_admin(festival_id)));
create policy "admins delete categories"
on public.categories for delete to authenticated
using ((select private.is_festival_admin(festival_id)));

create policy "members read products"
on public.products for select to authenticated
using ((select private.is_festival_member(festival_id)));
create policy "admins insert products"
on public.products for insert to authenticated
with check ((select private.is_festival_admin(festival_id)));
create policy "admins update products"
on public.products for update to authenticated
using ((select private.is_festival_admin(festival_id)))
with check ((select private.is_festival_admin(festival_id)));
create policy "admins delete products"
on public.products for delete to authenticated
using ((select private.is_festival_admin(festival_id)));

create policy "members read orders"
on public.orders for select to authenticated
using ((select private.is_festival_member(festival_id)));
create policy "members read order items"
on public.order_items for select to authenticated
using ((select private.is_festival_member(festival_id)));

create policy "members receive festival broadcasts"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and (select private.can_receive_festival_broadcast((select realtime.topic())))
);

-- Returns only non-sensitive festival fields. Failed attempts are committed and throttled.
create or replace function public.register_festival(
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

create or replace function public.login_festival(p_slug text, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  normalized_slug text := lower(trim(p_slug));
  throttle private.login_throttles;
  found public.festivals;
  next_failures smallint;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Autenticazione richiesta');
  end if;

  insert into private.login_throttles(user_id, festival_slug)
  values (auth.uid(), normalized_slug)
  on conflict do nothing;

  select * into throttle
  from private.login_throttles
  where user_id = auth.uid() and festival_slug = normalized_slug
  for update;

  if throttle.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Troppi tentativi. Riprova più tardi');
  end if;

  select * into found
  from public.festivals
  where slug = normalized_slug
    and pin_hash = extensions.crypt(p_pin, pin_hash);

  if found.id is null then
    next_failures := least(throttle.failures + 1, 20);
    update private.login_throttles
    set failures = next_failures,
        locked_until = case when next_failures >= 5 then now() + interval '15 minutes' end,
        updated_at = now()
    where user_id = auth.uid() and festival_slug = normalized_slug;
    return jsonb_build_object('ok', false, 'error', 'Attività o PIN non validi');
  end if;

  update private.login_throttles
  set failures = 0, locked_until = null, updated_at = now()
  where user_id = auth.uid() and festival_slug = normalized_slug;

  insert into public.festival_members(festival_id, user_id, role)
  values (found.id, auth.uid(), 'operator')
  on conflict (festival_id, user_id)
  do update set last_seen_at = now();

  return jsonb_build_object(
    'ok', true,
    'festival', jsonb_build_object('id', found.id, 'name', found.name, 'slug', found.slug)
  );
end;
$$;

create or replace function public.verify_stats_pin(p_festival_id uuid, p_pin text)
returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
declare
  valid boolean;
begin
  if not private.is_festival_member(p_festival_id) then
    return false;
  end if;

  select exists (
    select 1 from public.festivals
    where id = p_festival_id
      and stats_pin_hash = extensions.crypt(p_pin, stats_pin_hash)
  ) into valid;

  if valid then
    update public.festival_members
    set stats_access_until = now() + interval '8 hours', last_seen_at = now()
    where festival_id = p_festival_id and user_id = auth.uid();
  end if;

  return valid;
end;
$$;

create or replace function public.create_order(
  p_festival_id uuid,
  p_table_number text,
  p_notes text,
  p_items jsonb
)
returns bigint
language plpgsql volatile security definer set search_path = ''
as $$
declare
  requested record;
  product_row public.products;
  snapshot_items jsonb := '[]'::jsonb;
  order_total numeric(10,2) := 0;
  order_id bigint;
  festival_timezone text;
  has_kitchen boolean := false;
  has_bar boolean := false;
begin
  if not private.is_festival_member(p_festival_id) then
    raise exception 'access denied';
  end if;
  if char_length(trim(p_table_number)) not between 1 and 20
    or char_length(coalesce(p_notes, '')) > 500
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'invalid order';
  end if;

  for requested in
    select (entry->>'product_id')::uuid as product_id,
           sum((entry->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as entry
    where (entry->>'quantity') ~ '^[0-9]+$'
    group by (entry->>'product_id')::uuid
  loop
    if requested.quantity not between 1 and 999 then
      raise exception 'invalid quantity';
    end if;

    select * into product_row
    from public.products
    where id = requested.product_id
      and festival_id = p_festival_id
      and active = true;
    if product_row.id is null then
      raise exception 'invalid product';
    end if;

    order_total := order_total + product_row.price * requested.quantity;
    has_bar := has_bar or product_row.category in ('Bere', 'Bevande');
    has_kitchen := has_kitchen or product_row.category not in ('Bere', 'Bevande');
    snapshot_items := snapshot_items || jsonb_build_array(jsonb_build_object(
      'product_id', product_row.id,
      'name', product_row.name,
      'price', product_row.price,
      'quantity', requested.quantity,
      'category', product_row.category
    ));
  end loop;

  if jsonb_array_length(snapshot_items) = 0 then
    raise exception 'empty order';
  end if;

  select timezone into festival_timezone from public.festivals where id = p_festival_id;

  insert into public.orders(
    festival_id, service_date, table_number, notes, total,
    kitchen_done, bar_done, created_by
  ) values (
    p_festival_id,
    (now() at time zone festival_timezone)::date,
    trim(p_table_number), trim(coalesce(p_notes, '')), order_total,
    not has_kitchen, not has_bar, auth.uid()
  ) returning id into order_id;

  insert into public.order_items(
    order_id, festival_id, product_id, name, price, quantity, category
  )
  select order_id, p_festival_id, item.product_id, item.name, item.price, item.quantity, item.category
  from jsonb_to_recordset(snapshot_items) as item(
    product_id uuid, name text, price numeric, quantity smallint, category text
  );

  perform private.broadcast_festival_event(
    p_festival_id, 'db-change',
    jsonb_build_object('entity', 'order', 'operation', 'INSERT', 'order_id', order_id)
  );
  return order_id;
end;
$$;

create or replace function public.set_order_status(p_order_id bigint, p_status text)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare target_festival uuid;
begin
  select festival_id into target_festival from public.orders where id = p_order_id for update;
  if target_festival is null or not private.is_festival_member(target_festival) then
    raise exception 'access denied';
  end if;

  case p_status
    when 'kitchen_done' then
      update public.order_items
      set prepared_quantity = quantity
      where order_id = p_order_id and category not in ('Bere', 'Bevande');
      update public.orders set kitchen_done = true, kitchen_done_at = coalesce(kitchen_done_at, now()) where id = p_order_id;
    when 'bar_done' then
      update public.orders set bar_done = true, bar_done_at = coalesce(bar_done_at, now()) where id = p_order_id;
    when 'paid' then
      update public.orders set paid = true, paid_at = coalesce(paid_at, now()) where id = p_order_id;
    else
      raise exception 'invalid status';
  end case;

  perform private.broadcast_festival_event(
    target_festival, 'db-change',
    jsonb_build_object('entity', 'order', 'operation', 'UPDATE', 'order_id', p_order_id)
  );
end;
$$;

create or replace function public.complete_kitchen_product(
  p_festival_id uuid,
  p_product_name text,
  p_quantity integer
)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  target record;
  remaining integer := greatest(coalesce(p_quantity, 0), 0);
  prepared_now integer;
  prepared_total integer := 0;
begin
  if not private.is_festival_member(p_festival_id) then
    raise exception 'access denied';
  end if;
  if remaining = 0 then return 0; end if;

  for target in
    select item.id, item.quantity, item.prepared_quantity
    from public.order_items as item
    join public.orders as customer_order on customer_order.id = item.order_id
    where item.festival_id = p_festival_id
      and lower(item.name) = lower(p_product_name)
      and item.category not in ('Bere', 'Bevande')
      and item.prepared_quantity < item.quantity
    order by customer_order.created_at asc, customer_order.id asc, item.id asc
    for update of item skip locked
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
  set kitchen_done = true, kitchen_done_at = coalesce(kitchen_done_at, now())
  where customer_order.festival_id = p_festival_id
    and customer_order.kitchen_done = false
    and not exists (
      select 1 from public.order_items as item
      where item.order_id = customer_order.id
        and item.category not in ('Bere', 'Bevande')
        and item.prepared_quantity < item.quantity
    );

  if prepared_total > 0 then
    perform private.broadcast_festival_event(
      p_festival_id, 'db-change',
      jsonb_build_object('entity', 'kitchen', 'operation', 'UPDATE', 'product', p_product_name)
    );
  end if;
  return prepared_total;
end;
$$;

create or replace function public.get_festival_analytics(
  p_festival_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare result jsonb;
begin
  if not private.has_stats_access(p_festival_id) then
    raise exception 'stats access denied';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'invalid analytics range';
  end if;

  with selected_orders as materialized (
    select * from public.orders
    where festival_id = p_festival_id and service_date between p_from and p_to
  ), item_totals as materialized (
    select item.name, item.category,
           sum(item.quantity)::bigint as quantity,
           sum(item.price * item.quantity)::numeric(14,2) as revenue
    from public.order_items item
    join selected_orders customer_order on customer_order.id = item.order_id
    group by item.name, item.category
  ), daily as (
    select service_date as date,
           count(*)::bigint as orders,
           coalesce(sum(total) filter (where paid), 0)::numeric(14,2) as revenue
    from selected_orders group by service_date
  ), hourly_counts as (
    select extract(hour from created_at)::integer as hour, count(*)::bigint as value
    from selected_orders group by 1
  ), category_totals as (
    select item.category as label,
           sum(item.price * item.quantity)::numeric(14,2) as value
    from public.order_items item
    join selected_orders customer_order on customer_order.id = item.order_id and customer_order.paid
    group by item.category
  )
  select jsonb_build_object(
    'totalRevenue', coalesce((select sum(total) from selected_orders where paid), 0),
    'orderCount', (select count(*) from selected_orders),
    'paidCount', (select count(*) from selected_orders where paid),
    'portions', coalesce((select sum(quantity) from item_totals), 0),
    'open', (select count(*) from selected_orders where not paid),
    'openAmount', coalesce((select sum(total) from selected_orders where not paid), 0),
    'ready', (select count(*) from selected_orders where kitchen_done),
    'days', coalesce((select jsonb_agg(to_jsonb(daily) order by date) from daily), '[]'::jsonb),
    'hourly', (
      select jsonb_agg(jsonb_build_object('hour', hour, 'value', coalesce(hourly_counts.value, 0)) order by hour)
      from generate_series(0, 23) hour left join hourly_counts using (hour)
    ),
    'ranked', coalesce((
      select jsonb_agg(to_jsonb(ranked) order by quantity desc, name)
      from (select * from item_totals order by quantity desc, name limit 50) ranked
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(to_jsonb(category_totals) order by value desc) from category_totals
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

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

-- Keep privileged implementations outside the exposed schema. Public RPCs are
-- small security-invoker wrappers; membership checks remain inside private code.
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

-- Minimal Data API privileges. PIN hashes and private tables are never selectable.
revoke all on all tables in schema public from anon, authenticated;
grant select (id, name, slug, timezone, created_at) on public.festivals to authenticated;
grant select on public.festival_members to authenticated;
grant select, insert, update, delete on public.categories, public.products to authenticated;
grant select on public.orders, public.order_items to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke all on function public.register_festival(text, text, text, text) from public, anon;
revoke all on function public.login_festival(text, text) from public, anon;
revoke all on function public.verify_stats_pin(uuid, text) from public, anon;
revoke all on function public.create_order(uuid, text, text, jsonb) from public, anon;
revoke all on function public.set_order_status(bigint, text) from public, anon;
revoke all on function public.complete_kitchen_product(uuid, text, integer) from public, anon;
revoke all on function public.get_festival_analytics(uuid, date, date) from public, anon;
revoke all on function public.get_owned_festivals() from public, anon;
revoke all on function public.reset_festival_pin(uuid, text, text) from public, anon;

grant execute on function public.register_festival(text, text, text, text) to authenticated;
grant execute on function public.login_festival(text, text) to authenticated;
grant execute on function public.verify_stats_pin(uuid, text) to authenticated;
grant execute on function public.create_order(uuid, text, text, jsonb) to authenticated;
grant execute on function public.set_order_status(bigint, text) to authenticated;
grant execute on function public.complete_kitchen_product(uuid, text, integer) to authenticated;
grant execute on function public.get_festival_analytics(uuid, date, date) to authenticated;
grant execute on function public.get_owned_festivals() to authenticated;
grant execute on function public.reset_festival_pin(uuid, text, text) to authenticated;


-- Product creation is exposed through a narrow membership-checked RPC.
create or replace function private.create_product(
  p_festival_id uuid,
  p_name text,
  p_price numeric,
  p_category text
)
returns public.products
language plpgsql volatile security definer set search_path = ''
as $$
declare
  created public.products;
begin
  if not private.is_festival_member(p_festival_id) then
    raise exception using errcode = '42501', message = 'Accesso evento non valido';
  end if;
  if char_length(trim(p_name)) not between 1 and 100
    or p_price is null or p_price < 0 or p_price > 99999.99
    or char_length(trim(p_category)) not between 1 and 60 then
    raise exception using errcode = '22023', message = 'Dati prodotto non validi';
  end if;
  if not exists (
    select 1 from public.categories
    where festival_id = p_festival_id and name = trim(p_category)
  ) then
    raise exception using errcode = '22023', message = 'Categoria non valida';
  end if;
  insert into public.products(festival_id, name, price, category)
  values (p_festival_id, trim(p_name), p_price, trim(p_category))
  returning * into created;
  return created;
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'Esiste già un prodotto con questo nome';
end;
$$;

revoke all on function private.create_product(uuid, text, numeric, text) from public, anon, authenticated;
grant execute on function private.create_product(uuid, text, numeric, text) to authenticated;

create function public.create_product(p_festival_id uuid, p_name text, p_price numeric, p_category text)
returns public.products language sql volatile security invoker set search_path = ''
as $$ select private.create_product(p_festival_id, p_name, p_price, p_category) $$;
revoke all on function public.create_product(uuid, text, numeric, text) from public, anon;
grant execute on function public.create_product(uuid, text, numeric, text) to authenticated;


-- Customer order-capacity upgrade requests and Manager approval workflow.
create table public.order_upgrade_requests (
  id bigint generated always as identity primary key,
  festival_id uuid not null references public.festivals(id) on delete cascade,
  requested_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  current_plan text not null
    check (current_plan in ('starter', 'pro', 'premium', 'enterprise')),
  suggested_plan text not null
    check (suggested_plan in ('pro', 'premium', 'enterprise')),
  current_max_orders integer not null check (current_max_orders > 0),
  suggested_additional_orders integer not null check (suggested_additional_orders > 0),
  client_message text not null default
    'La richiesta comporta il passaggio al piano superiore e una variazione di prezzo.',
  resolution_notes text not null default '',
  extension_id bigint references public.order_limit_extensions(id) on delete set null,
  requested_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null
);

create unique index order_upgrade_requests_one_pending_idx
on public.order_upgrade_requests(festival_id)
where status = 'pending';

create index order_upgrade_requests_manager_idx
on public.order_upgrade_requests(status, requested_at desc);

create index order_upgrade_requests_requested_by_idx
on public.order_upgrade_requests(requested_by) where requested_by is not null;
create index order_upgrade_requests_resolved_by_idx
on public.order_upgrade_requests(resolved_by) where resolved_by is not null;
create index order_upgrade_requests_extension_idx
on public.order_upgrade_requests(extension_id) where extension_id is not null;

alter table public.order_upgrade_requests enable row level security;
revoke all on public.order_upgrade_requests from anon, authenticated;

create or replace function private.request_order_upgrade(p_festival_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.event_licenses;
  request_row public.order_upgrade_requests;
  next_plan text;
  suggested_orders integer;
begin
  if not private.is_festival_member(p_festival_id) then
    raise exception using errcode = '42501', message = 'Accesso evento non valido';
  end if;

  select * into target
  from public.event_licenses
  where festival_id = p_festival_id
  for update;

  if target.festival_id is null then
    raise exception using errcode = 'P0002', message = 'Licenza evento non trovata';
  end if;
  if target.orders_used < target.max_orders then
    raise exception using errcode = '22023', message = 'Il limite ordini non è ancora stato raggiunto';
  end if;
  if target.status <> 'active'
    or current_date < target.start_date
    or current_date > target.end_date then
    raise exception using errcode = '22023', message = 'La licenza non è attiva';
  end if;

  select * into request_row
  from public.order_upgrade_requests
  where festival_id = p_festival_id
    and status = 'pending';

  if request_row.id is not null then
    return jsonb_build_object(
      'id', request_row.id,
      'status', request_row.status,
      'current_plan', request_row.current_plan,
      'suggested_plan', request_row.suggested_plan,
      'suggested_additional_orders', request_row.suggested_additional_orders,
      'requested_at', request_row.requested_at,
      'message', request_row.client_message
    );
  end if;

  next_plan := case target.plan
    when 'starter' then 'pro'
    when 'pro' then 'premium'
    else 'enterprise'
  end;
  suggested_orders := case target.plan
    when 'starter' then greatest(1, 5000 - target.max_orders)
    when 'pro' then greatest(1, 15000 - target.max_orders)
    when 'premium' then 15000
    else greatest(1000, ceil(target.max_orders * 0.5)::integer)
  end;

  insert into public.order_upgrade_requests(
    festival_id, requested_by, current_plan, suggested_plan,
    current_max_orders, suggested_additional_orders
  ) values (
    p_festival_id, auth.uid(), target.plan, next_plan,
    target.max_orders, suggested_orders
  )
  returning * into request_row;

  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (
    p_festival_id, auth.uid(), 'order_upgrade_requested',
    jsonb_build_object(
      'request_id', request_row.id,
      'current_plan', request_row.current_plan,
      'suggested_plan', request_row.suggested_plan
    )
  );

  return jsonb_build_object(
    'id', request_row.id,
    'status', request_row.status,
    'current_plan', request_row.current_plan,
    'suggested_plan', request_row.suggested_plan,
    'suggested_additional_orders', request_row.suggested_additional_orders,
    'requested_at', request_row.requested_at,
    'message', request_row.client_message
  );
end;
$$;

create or replace function private.get_my_order_upgrade_request(p_festival_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not private.is_festival_member(p_festival_id) then null
    else (
      select jsonb_build_object(
        'id', request.id,
        'status', request.status,
        'current_plan', request.current_plan,
        'suggested_plan', request.suggested_plan,
        'suggested_additional_orders', request.suggested_additional_orders,
        'requested_at', request.requested_at,
        'message', request.client_message
      )
      from public.order_upgrade_requests request
      where request.festival_id = p_festival_id
        and request.status = 'pending'
      order by request.requested_at desc
      limit 1
    )
  end
$$;

create or replace function private.manager_list_order_upgrade_requests(
  p_festival_id uuid default null,
  p_status text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare result jsonb;
begin
  if not private.is_platform_admin() then
    raise exception using errcode = '42501', message = 'admin access required';
  end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected') then
    raise exception using errcode = '22023', message = 'Stato richiesta non valido';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', request.id,
    'festival_id', request.festival_id,
    'event_name', festival.name,
    'event_slug', festival.slug,
    'client_name', client.name,
    'current_plan', request.current_plan,
    'suggested_plan', request.suggested_plan,
    'current_max_orders', request.current_max_orders,
    'suggested_additional_orders', request.suggested_additional_orders,
    'status', request.status,
    'client_message', request.client_message,
    'resolution_notes', request.resolution_notes,
    'extension_id', request.extension_id,
    'requested_at', request.requested_at,
    'resolved_at', request.resolved_at
  ) order by request.requested_at desc), '[]'::jsonb)
  into result
  from public.order_upgrade_requests request
  join public.festivals festival on festival.id = request.festival_id
  join public.event_licenses license on license.festival_id = request.festival_id
  left join public.clients client on client.id = license.client_id
  where (p_festival_id is null or request.festival_id = p_festival_id)
    and (p_status is null or request.status = p_status);

  return result;
end;
$$;

create or replace function private.manager_approve_order_upgrade_request(
  p_request_id bigint,
  p_added_orders integer,
  p_supplement_amount numeric,
  p_notes text default ''
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  request_row public.order_upgrade_requests;
  license_row public.event_licenses;
  created_extension_id bigint;
  baseline_orders integer;
  new_max_orders integer;
  actual_added_orders integer;
  new_devices integer;
  new_daily_price numeric;
begin
  if not private.is_platform_admin() then
    raise exception using errcode = '42501', message = 'admin access required';
  end if;
  if p_added_orders not between 1 and 10000000
    or coalesce(p_supplement_amount, 0) < 0
    or char_length(coalesce(p_notes, '')) > 500 then
    raise exception using errcode = '22023', message = 'Dati approvazione non validi';
  end if;

  select * into request_row
  from public.order_upgrade_requests
  where id = p_request_id
  for update;

  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Richiesta non trovata';
  end if;
  if request_row.status <> 'pending' then
    raise exception using errcode = '22023', message = 'Richiesta già elaborata';
  end if;

  select * into license_row
  from public.event_licenses
  where festival_id = request_row.festival_id
  for update;

  baseline_orders := case request_row.suggested_plan
    when 'pro' then 5000
    when 'premium' then 15000
    else license_row.max_orders + p_added_orders
  end;
  new_max_orders := greatest(license_row.max_orders + p_added_orders, baseline_orders);
  actual_added_orders := new_max_orders - license_row.max_orders;
  new_devices := case request_row.suggested_plan
    when 'pro' then greatest(license_row.max_devices, 15)
    when 'premium' then greatest(license_row.max_devices, 30)
    else license_row.max_devices
  end;
  new_daily_price := case request_row.suggested_plan
    when 'pro' then 25
    when 'premium' then 40
    else license_row.daily_price
  end;

  update public.event_licenses
  set plan = request_row.suggested_plan,
      max_orders = new_max_orders,
      max_devices = new_devices,
      daily_price = new_daily_price,
      updated_at = now()
  where festival_id = request_row.festival_id;

  insert into public.order_limit_extensions(
    festival_id, added_orders, supplement_amount, notes, created_by
  ) values (
    request_row.festival_id,
    actual_added_orders,
    coalesce(p_supplement_amount, 0),
    trim(concat('Upgrade ', request_row.current_plan, ' -> ', request_row.suggested_plan,
      case when coalesce(trim(p_notes), '') <> '' then ': ' || trim(p_notes) else '' end)),
    auth.uid()
  )
  returning id into created_extension_id;

  update public.order_upgrade_requests
  set status = 'approved',
      extension_id = created_extension_id,
      resolution_notes = trim(coalesce(p_notes, '')),
      resolved_at = now(),
      resolved_by = auth.uid()
  where id = request_row.id;

  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (
    request_row.festival_id, auth.uid(), 'order_upgrade_approved',
    jsonb_build_object(
      'request_id', request_row.id,
      'extension_id', created_extension_id,
      'old_plan', request_row.current_plan,
      'new_plan', request_row.suggested_plan,
      'added_orders', actual_added_orders,
      'supplement_amount', coalesce(p_supplement_amount, 0)
    )
  );

  return jsonb_build_object(
    'request_id', request_row.id,
    'extension_id', created_extension_id,
    'new_plan', request_row.suggested_plan,
    'added_orders', actual_added_orders,
    'new_max_orders', new_max_orders
  );
end;
$$;

create or replace function private.manager_reject_order_upgrade_request(
  p_request_id bigint,
  p_notes text default ''
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare target_festival uuid;
begin
  if not private.is_platform_admin() then
    raise exception using errcode = '42501', message = 'admin access required';
  end if;
  if char_length(coalesce(p_notes, '')) > 500 then
    raise exception using errcode = '22023', message = 'Nota troppo lunga';
  end if;

  update public.order_upgrade_requests
  set status = 'rejected',
      resolution_notes = trim(coalesce(p_notes, '')),
      resolved_at = now(),
      resolved_by = auth.uid()
  where id = p_request_id
    and status = 'pending'
  returning festival_id into target_festival;

  if target_festival is null then
    raise exception using errcode = '22023', message = 'Richiesta non trovata o già elaborata';
  end if;

  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (
    target_festival, auth.uid(), 'order_upgrade_rejected',
    jsonb_build_object('request_id', p_request_id, 'notes', trim(coalesce(p_notes, '')))
  );
end;
$$;

revoke all on function private.request_order_upgrade(uuid) from public, anon, authenticated;
revoke all on function private.get_my_order_upgrade_request(uuid) from public, anon, authenticated;
revoke all on function private.manager_list_order_upgrade_requests(uuid, text) from public, anon, authenticated;
revoke all on function private.manager_approve_order_upgrade_request(bigint, integer, numeric, text) from public, anon, authenticated;
revoke all on function private.manager_reject_order_upgrade_request(bigint, text) from public, anon, authenticated;

grant execute on function private.request_order_upgrade(uuid) to authenticated;
grant execute on function private.get_my_order_upgrade_request(uuid) to authenticated;
grant execute on function private.manager_list_order_upgrade_requests(uuid, text) to authenticated;
grant execute on function private.manager_approve_order_upgrade_request(bigint, integer, numeric, text) to authenticated;
grant execute on function private.manager_reject_order_upgrade_request(bigint, text) to authenticated;

create function public.request_order_upgrade(p_festival_id uuid)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.request_order_upgrade(p_festival_id) $$;

create function public.get_my_order_upgrade_request(p_festival_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.get_my_order_upgrade_request(p_festival_id) $$;

create function public.manager_list_order_upgrade_requests(
  p_festival_id uuid default null,
  p_status text default null
)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.manager_list_order_upgrade_requests(p_festival_id, p_status) $$;

create function public.manager_approve_order_upgrade_request(
  p_request_id bigint,
  p_added_orders integer,
  p_supplement_amount numeric,
  p_notes text default ''
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.manager_approve_order_upgrade_request(p_request_id, p_added_orders, p_supplement_amount, p_notes) $$;

create function public.manager_reject_order_upgrade_request(
  p_request_id bigint,
  p_notes text default ''
)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.manager_reject_order_upgrade_request(p_request_id, p_notes) $$;

revoke all on function public.request_order_upgrade(uuid) from public, anon;
revoke all on function public.get_my_order_upgrade_request(uuid) from public, anon;
revoke all on function public.manager_list_order_upgrade_requests(uuid, text) from public, anon;
revoke all on function public.manager_approve_order_upgrade_request(bigint, integer, numeric, text) from public, anon;
revoke all on function public.manager_reject_order_upgrade_request(bigint, text) from public, anon;

grant execute on function public.request_order_upgrade(uuid) to authenticated;
grant execute on function public.get_my_order_upgrade_request(uuid) to authenticated;
grant execute on function public.manager_list_order_upgrade_requests(uuid, text) to authenticated;
grant execute on function public.manager_approve_order_upgrade_request(bigint, integer, numeric, text) to authenticated;
grant execute on function public.manager_reject_order_upgrade_request(bigint, text) to authenticated;

commit;
