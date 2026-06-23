-- Commercial order-capacity extensions and safe operational data cleanup.
alter table public.event_licenses
  add column data_cleared_at timestamptz;

create table public.order_limit_extensions (
  id bigint generated always as identity primary key,
  festival_id uuid not null references public.festivals(id) on delete cascade,
  added_orders integer not null check (added_orders between 1 and 10000000),
  supplement_amount numeric(12,2) not null default 0 check (supplement_amount >= 0),
  payment_status text not null default 'pending'
    check (payment_status in ('pending', 'paid', 'waived')),
  notes text not null default '' check (char_length(notes) <= 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create index order_extensions_festival_created_idx
on public.order_limit_extensions(festival_id, created_at desc);
create index order_extensions_created_by_idx
on public.order_limit_extensions(created_by) where created_by is not null;

alter table public.order_limit_extensions enable row level security;
revoke all on public.order_limit_extensions from anon, authenticated;

create or replace function private.manager_add_orders(
  p_festival_id uuid,
  p_added_orders integer,
  p_supplement_amount numeric,
  p_notes text default ''
)
returns bigint language plpgsql volatile security definer set search_path = ''
as $$
declare extension_id bigint;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  if p_added_orders not between 1 and 10000000
    or coalesce(p_supplement_amount, 0) < 0
    or char_length(coalesce(p_notes, '')) > 500 then
    raise exception 'Dati proroga ordini non validi';
  end if;

  perform 1 from public.event_licenses where festival_id = p_festival_id for update;
  if not found then raise exception 'event not found'; end if;

  update public.event_licenses
  set max_orders = max_orders + p_added_orders, updated_at = now()
  where festival_id = p_festival_id;

  insert into public.order_limit_extensions(
    festival_id, added_orders, supplement_amount, notes, created_by
  ) values (
    p_festival_id, p_added_orders, coalesce(p_supplement_amount, 0),
    trim(coalesce(p_notes, '')), auth.uid()
  ) returning id into extension_id;

  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (
    p_festival_id, auth.uid(), 'orders_extended',
    jsonb_build_object(
      'extension_id', extension_id,
      'added_orders', p_added_orders,
      'supplement_amount', coalesce(p_supplement_amount, 0),
      'payment_status', 'pending'
    )
  );
  return extension_id;
end;
$$;

create or replace function private.manager_mark_order_extension_paid(p_extension_id bigint)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare target_festival uuid;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  update public.order_limit_extensions
  set payment_status = 'paid', paid_at = now()
  where id = p_extension_id
  returning festival_id into target_festival;
  if target_festival is null then raise exception 'extension not found'; end if;
  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (target_festival, auth.uid(), 'order_extension_paid', jsonb_build_object('extension_id', p_extension_id));
end;
$$;

create or replace function private.manager_list_order_extensions(p_festival_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare result jsonb;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', extension.id,
    'festival_id', extension.festival_id,
    'event_name', festival.name,
    'added_orders', extension.added_orders,
    'supplement_amount', extension.supplement_amount,
    'payment_status', extension.payment_status,
    'notes', extension.notes,
    'created_at', extension.created_at,
    'paid_at', extension.paid_at
  ) order by extension.created_at desc), '[]'::jsonb)
  into result
  from public.order_limit_extensions extension
  join public.festivals festival on festival.id = extension.festival_id
  where p_festival_id is null or extension.festival_id = p_festival_id;
  return result;
end;
$$;

create or replace function private.manager_clear_event_data(
  p_festival_id uuid,
  p_confirmation_slug text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  target public.event_licenses;
  target_slug text;
  deleted_orders bigint;
  deleted_products bigint;
  deleted_categories bigint;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  select * into target
  from public.event_licenses
  where festival_id = p_festival_id
  for update;
  select slug into target_slug from public.festivals where id = p_festival_id;
  if target.festival_id is null then raise exception 'event not found'; end if;
  if lower(trim(p_confirmation_slug)) <> target_slug then
    raise exception 'Codice evento di conferma non corretto';
  end if;
  if target.status not in ('suspended', 'expired') and target.end_date >= current_date then
    raise exception 'Sospendi o lascia scadere l evento prima di cancellarne i dati';
  end if;

  select count(*) into deleted_orders from public.orders where festival_id = p_festival_id;
  select count(*) into deleted_products from public.products where festival_id = p_festival_id;
  select count(*) into deleted_categories from public.categories where festival_id = p_festival_id;

  delete from public.orders where festival_id = p_festival_id;
  delete from public.products where festival_id = p_festival_id;
  delete from public.categories where festival_id = p_festival_id;
  delete from public.active_sessions where festival_id = p_festival_id;
  update public.event_licenses
  set orders_used = 0, data_cleared_at = now(), updated_at = now()
  where festival_id = p_festival_id;

  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (
    p_festival_id, auth.uid(), 'operational_data_cleared',
    jsonb_build_object(
      'orders', deleted_orders,
      'products', deleted_products,
      'categories', deleted_categories
    )
  );
  return jsonb_build_object(
    'orders', deleted_orders,
    'products', deleted_products,
    'categories', deleted_categories
  );
end;
$$;

create function public.manager_add_orders(
  p_festival_id uuid, p_added_orders integer,
  p_supplement_amount numeric, p_notes text default ''
)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select private.manager_add_orders(p_festival_id, p_added_orders, p_supplement_amount, p_notes) $$;
create function public.manager_mark_order_extension_paid(p_extension_id bigint)
returns void language sql volatile security invoker set search_path = ''
as $$ select private.manager_mark_order_extension_paid(p_extension_id) $$;
create function public.manager_list_order_extensions(p_festival_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.manager_list_order_extensions(p_festival_id) $$;
create function public.manager_clear_event_data(p_festival_id uuid, p_confirmation_slug text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.manager_clear_event_data(p_festival_id, p_confirmation_slug) $$;

revoke all on function private.manager_add_orders(uuid,integer,numeric,text) from public,anon;
revoke all on function private.manager_mark_order_extension_paid(bigint) from public,anon;
revoke all on function private.manager_list_order_extensions(uuid) from public,anon;
revoke all on function private.manager_clear_event_data(uuid,text) from public,anon;
grant execute on function private.manager_add_orders(uuid,integer,numeric,text) to authenticated;
grant execute on function private.manager_mark_order_extension_paid(bigint) to authenticated;
grant execute on function private.manager_list_order_extensions(uuid) to authenticated;
grant execute on function private.manager_clear_event_data(uuid,text) to authenticated;

revoke all on function public.manager_add_orders(uuid,integer,numeric,text) from public,anon;
revoke all on function public.manager_mark_order_extension_paid(bigint) from public,anon;
revoke all on function public.manager_list_order_extensions(uuid) from public,anon;
revoke all on function public.manager_clear_event_data(uuid,text) from public,anon;
grant execute on function public.manager_add_orders(uuid,integer,numeric,text) to authenticated;
grant execute on function public.manager_mark_order_extension_paid(bigint) to authenticated;
grant execute on function public.manager_list_order_extensions(uuid) to authenticated;
grant execute on function public.manager_clear_event_data(uuid,text) to authenticated;

-- Clearer blocking messages; the locking behavior remains unchanged.
create or replace function private.register_device_session(
  p_festival_id uuid, p_device_id text, p_device_name text, p_user_agent text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare target public.event_licenses; blocked jsonb; active_count integer; existing boolean;
begin
  if auth.uid() is null or not private.is_festival_member(p_festival_id) then raise exception 'access denied'; end if;
  if char_length(p_device_id) not between 8 and 128 then raise exception 'invalid device'; end if;
  select * into target from public.event_licenses where festival_id = p_festival_id for update;
  blocked := private.license_message(target);
  if blocked is not null then return blocked || jsonb_build_object('allowed', false); end if;
  delete from public.active_sessions where festival_id = p_festival_id and last_seen < now() - interval '5 minutes';
  select exists(select 1 from public.active_sessions where festival_id = p_festival_id and device_id = p_device_id) into existing;
  select count(*) into active_count from public.active_sessions where festival_id = p_festival_id and last_seen >= now() - interval '5 minutes';
  if not existing and active_count >= target.max_devices then
    return jsonb_build_object(
      'allowed', false, 'code', 'device_limit',
      'message', 'Dispositivi massimi raggiunti. Non è possibile accedere da un altro dispositivo.',
      'active_devices', active_count, 'max_devices', target.max_devices
    );
  end if;
  insert into public.active_sessions(festival_id, auth_user_id, device_id, device_name, user_agent)
  values (p_festival_id, auth.uid(), p_device_id, left(coalesce(p_device_name, ''), 120), left(coalesce(p_user_agent, ''), 500))
  on conflict (festival_id, device_id) do update
  set auth_user_id = auth.uid(), device_name = excluded.device_name, user_agent = excluded.user_agent, last_seen = now();
  return jsonb_build_object(
    'allowed', true, 'code', 'active', 'message', '', 'plan', target.plan, 'status', target.status,
    'start_date', target.start_date, 'end_date', target.end_date,
    'orders_used', target.orders_used, 'max_orders', target.max_orders,
    'orders_remaining', greatest(target.max_orders - target.orders_used, 0),
    'active_devices', case when existing then active_count else active_count + 1 end,
    'max_devices', target.max_devices
  );
end;
$$;

create or replace function private.create_order(
  p_festival_id uuid, p_table_number text, p_notes text, p_items jsonb, p_device_id text
)
returns bigint language plpgsql volatile security definer set search_path = ''
as $$
declare
  requested record; product_row public.products; target public.event_licenses; blocked jsonb;
  snapshot_items jsonb := '[]'::jsonb; order_total numeric(10,2) := 0; order_id bigint;
  festival_timezone text; has_kitchen boolean := false; has_bar boolean := false;
begin
  if not private.is_festival_member(p_festival_id) then raise exception 'access denied'; end if;
  select * into target from public.event_licenses where festival_id=p_festival_id for update;
  blocked := private.license_message(target);
  if blocked is not null then raise exception '%', blocked->>'message'; end if;
  if target.orders_used >= target.max_orders then
    raise exception 'Limite massimo di ordini raggiunto. Non è possibile aggiungere altri ordini.';
  end if;
  if not exists(select 1 from public.active_sessions where festival_id=p_festival_id and device_id=p_device_id and auth_user_id=auth.uid() and last_seen>=now()-interval '5 minutes') then
    raise exception 'Dispositivo non autorizzato o sessione scaduta. Riapri il gestionale.';
  end if;
  if char_length(trim(p_table_number)) not between 1 and 20 or char_length(coalesce(p_notes,''))>500 or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid order'; end if;
  for requested in select (entry->>'product_id')::uuid product_id, sum((entry->>'quantity')::integer)::integer quantity from jsonb_array_elements(p_items) entry where (entry->>'quantity')~'^[0-9]+$' group by (entry->>'product_id')::uuid loop
    if requested.quantity not between 1 and 999 then raise exception 'invalid quantity'; end if;
    select * into product_row from public.products where id=requested.product_id and festival_id=p_festival_id and active=true;
    if product_row.id is null then raise exception 'invalid product'; end if;
    order_total:=order_total+product_row.price*requested.quantity;
    has_bar:=has_bar or product_row.category in ('Bere','Bevande'); has_kitchen:=has_kitchen or product_row.category not in ('Bere','Bevande');
    snapshot_items:=snapshot_items||jsonb_build_array(jsonb_build_object('product_id',product_row.id,'name',product_row.name,'price',product_row.price,'quantity',requested.quantity,'category',product_row.category));
  end loop;
  if jsonb_array_length(snapshot_items)=0 then raise exception 'empty order'; end if;
  select timezone into festival_timezone from public.festivals where id=p_festival_id;
  insert into public.orders(festival_id,service_date,table_number,notes,total,kitchen_done,bar_done,created_by)
  values(p_festival_id,(now() at time zone festival_timezone)::date,trim(p_table_number),trim(coalesce(p_notes,'')),order_total,not has_kitchen,not has_bar,auth.uid()) returning id into order_id;
  insert into public.order_items(order_id,festival_id,product_id,name,price,quantity,category)
  select order_id,p_festival_id,item.product_id,item.name,item.price,item.quantity,item.category from jsonb_to_recordset(snapshot_items) item(product_id uuid,name text,price numeric,quantity smallint,category text);
  update public.event_licenses set orders_used=orders_used+1,updated_at=now() where festival_id=p_festival_id;
  perform private.broadcast_festival_event(p_festival_id,'db-change',jsonb_build_object('entity','order','operation','INSERT','order_id',order_id));
  return order_id;
end;
$$;
