-- Ordiva Manager, commercial licenses and server-side usage enforcement.
begin;

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null default 'cliente' check (role in ('admin', 'cliente', 'operatore')),
  name text not null default '',
  email text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 120),
  contact_name text not null default '',
  email text not null default '',
  phone text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.event_licenses (
  festival_id uuid primary key references public.festivals(id) on delete cascade,
  client_id uuid references public.clients(id) on delete restrict,
  plan text not null check (plan in ('starter', 'pro', 'premium', 'enterprise')),
  status text not null default 'draft' check (status in ('active', 'suspended', 'expired', 'draft')),
  start_date date not null,
  end_date date not null,
  purchased_days integer not null check (purchased_days > 0 and purchased_days <= 3660),
  max_devices integer not null check (max_devices > 0 and max_devices <= 10000),
  max_orders integer not null check (max_orders > 0 and max_orders <= 100000000),
  orders_used integer not null default 0 check (orders_used >= 0),
  daily_price numeric(10,2) not null default 0 check (daily_price >= 0),
  activation_fee numeric(10,2) not null default 49 check (activation_fee >= 0),
  total_paid numeric(12,2) not null default 0 check (total_paid >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'paid', 'refunded', 'manual')),
  internal_notes text not null default '',
  is_test boolean not null default false,
  stripe_customer_id text,
  stripe_subscription_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);

alter table public.festival_members
  add column event_role text not null default 'staff'
    check (event_role in ('owner', 'cassiere', 'cucina', 'bar', 'staff')),
  add column username text;

create table public.active_sessions (
  id bigint generated always as identity primary key,
  festival_id uuid not null references public.festivals(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null check (char_length(device_id) between 8 and 128),
  device_name text not null default '' check (char_length(device_name) <= 120),
  user_agent text not null default '' check (char_length(user_agent) <= 500),
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (festival_id, device_id)
);

create table public.license_audit_logs (
  id bigint generated always as identity primary key,
  festival_id uuid references public.festivals(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index clients_name_idx on public.clients (lower(name));
create index licenses_status_end_idx on public.event_licenses(status, end_date);
create index licenses_client_idx on public.event_licenses(client_id);
create index sessions_festival_active_idx on public.active_sessions(festival_id, last_seen desc);
create index sessions_user_idx on public.active_sessions(auth_user_id, festival_id);
create index audit_festival_created_idx on public.license_audit_logs(festival_id, created_at desc);

-- Existing installations keep working while they are moved to commercial plans.
insert into public.clients(name, notes)
select festival.name, 'Cliente legacy creato automaticamente'
from public.festivals as festival
where not exists (select 1 from public.event_licenses where festival_id = festival.id);

insert into public.event_licenses(
  festival_id, client_id, plan, status, start_date, end_date, purchased_days,
  max_devices, max_orders, orders_used, daily_price, activation_fee,
  payment_status, internal_notes
)
select festival.id, client.id, 'enterprise', 'active', current_date,
       current_date + 3650, 3651, 100, 1000000,
       (select count(*) from public.orders where festival_id = festival.id),
       0, 0, 'manual', 'Licenza legacy: verificare e assegnare un piano commerciale'
from public.festivals as festival
join lateral (
  select id from public.clients
  where name = festival.name and notes = 'Cliente legacy creato automaticamente'
  order by created_at desc limit 1
) as client on true
where not exists (select 1 from public.event_licenses where festival_id = festival.id);

-- Bootstrap the only permanent account already present in this project.
insert into public.profiles(auth_user_id, role, name, email)
values (
  'e4300509-8f26-4c73-a6a5-c635a1c8ed2a',
  'admin', 'Matteo Cambielli', 'matteo.cambie05@gmail.com'
)
on conflict (auth_user_id) do update
set role = 'admin', name = excluded.name, email = excluded.email, updated_at = now();

alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.event_licenses enable row level security;
alter table public.active_sessions enable row level security;
alter table public.license_audit_logs enable row level security;

create or replace function private.is_platform_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where auth_user_id = (select auth.uid()) and role = 'admin'
  );
$$;

revoke all on function private.is_platform_admin() from public, anon;
grant execute on function private.is_platform_admin() to authenticated;

create policy "profiles self or admin read" on public.profiles
for select to authenticated
using (auth_user_id = (select auth.uid()) or (select private.is_platform_admin()));
create policy "admins manage profiles" on public.profiles
for all to authenticated
using ((select private.is_platform_admin()))
with check ((select private.is_platform_admin()));

create policy "admins manage clients" on public.clients
for all to authenticated
using ((select private.is_platform_admin()))
with check ((select private.is_platform_admin()));

create policy "admins or members read licenses" on public.event_licenses
for select to authenticated
using ((select private.is_platform_admin()) or (select private.is_festival_member(festival_id)));
create policy "admins manage licenses" on public.event_licenses
for all to authenticated
using ((select private.is_platform_admin()))
with check ((select private.is_platform_admin()));

create policy "admins or session owners read sessions" on public.active_sessions
for select to authenticated
using ((select private.is_platform_admin()) or auth_user_id = (select auth.uid()));
create policy "admins manage sessions" on public.active_sessions
for all to authenticated
using ((select private.is_platform_admin()))
with check ((select private.is_platform_admin()));

create policy "admins read audit" on public.license_audit_logs
for select to authenticated using ((select private.is_platform_admin()));

create or replace function public.is_platform_admin()
returns boolean language sql stable security invoker set search_path = ''
as $$ select private.is_platform_admin() $$;

create or replace function private.license_message(target public.event_licenses)
returns jsonb language plpgsql stable set search_path = ''
as $$
begin
  if target.festival_id is null then
    return jsonb_build_object('code', 'license_missing', 'message', 'Licenza evento non configurata. Contattaci per assistenza.');
  elsif target.status = 'suspended' then
    return jsonb_build_object('code', 'suspended', 'message', 'Il tuo evento è momentaneamente sospeso. Contattaci per assistenza.');
  elsif target.status = 'draft' or current_date < target.start_date then
    return jsonb_build_object('code', 'not_started', 'message', 'Il periodo di utilizzo del tuo evento non è ancora iniziato.');
  elsif target.status = 'expired' or current_date > target.end_date then
    return jsonb_build_object('code', 'expired', 'message', 'Il periodo di utilizzo del tuo evento è terminato. Contattaci per riattivarlo.');
  end if;
  return null;
end;
$$;

create or replace function private.register_device_session(
  p_festival_id uuid, p_device_id text, p_device_name text, p_user_agent text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare target public.event_licenses; blocked jsonb; active_count integer; existing boolean;
begin
  if auth.uid() is null or not private.is_festival_member(p_festival_id) then
    raise exception 'access denied';
  end if;
  if char_length(p_device_id) not between 8 and 128 then raise exception 'invalid device'; end if;

  select * into target from public.event_licenses where festival_id = p_festival_id for update;
  blocked := private.license_message(target);
  if blocked is not null then return blocked || jsonb_build_object('allowed', false); end if;

  delete from public.active_sessions
  where festival_id = p_festival_id and last_seen < now() - interval '5 minutes';
  select exists(select 1 from public.active_sessions where festival_id = p_festival_id and device_id = p_device_id)
  into existing;
  select count(*) into active_count from public.active_sessions
  where festival_id = p_festival_id and last_seen >= now() - interval '5 minutes';

  if not existing and active_count >= target.max_devices then
    return jsonb_build_object(
      'allowed', false, 'code', 'device_limit',
      'message', 'Limite dispositivi raggiunto. Chiudi il gestionale su un altro dispositivo o contattaci per aumentare il piano.',
      'active_devices', active_count, 'max_devices', target.max_devices
    );
  end if;

  insert into public.active_sessions(festival_id, auth_user_id, device_id, device_name, user_agent)
  values (p_festival_id, auth.uid(), p_device_id, left(coalesce(p_device_name, ''), 120), left(coalesce(p_user_agent, ''), 500))
  on conflict (festival_id, device_id) do update
  set auth_user_id = auth.uid(), device_name = excluded.device_name,
      user_agent = excluded.user_agent, last_seen = now();

  return jsonb_build_object(
    'allowed', true, 'code', 'active', 'message', '',
    'plan', target.plan, 'status', target.status,
    'start_date', target.start_date, 'end_date', target.end_date,
    'orders_used', target.orders_used, 'max_orders', target.max_orders,
    'orders_remaining', greatest(target.max_orders - target.orders_used, 0),
    'active_devices', case when existing then active_count else active_count + 1 end,
    'max_devices', target.max_devices
  );
end;
$$;

create or replace function public.register_device_session(
  p_festival_id uuid, p_device_id text, p_device_name text default '', p_user_agent text default ''
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.register_device_session(p_festival_id, p_device_id, p_device_name, p_user_agent) $$;

create or replace function public.release_device_session(p_festival_id uuid, p_device_id text)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
begin
  delete from public.active_sessions
  where festival_id = p_festival_id and device_id = p_device_id and auth_user_id = auth.uid();
end;
$$;

create or replace function public.get_my_festivals()
returns jsonb language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', festival.id, 'name', festival.name, 'slug', festival.slug,
    'role', membership.event_role, 'status', license.status,
    'start_date', license.start_date, 'end_date', license.end_date
  ) order by festival.created_at desc), '[]'::jsonb)
  from public.festival_members membership
  join public.festivals festival on festival.id = membership.festival_id
  join public.event_licenses license on license.festival_id = festival.id
  where membership.user_id = (select auth.uid());
$$;

create or replace function private.manager_dashboard()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case when not private.is_platform_admin() then null else jsonb_build_object(
    'events_total', count(*),
    'events_active', count(*) filter (where license.status = 'active' and current_date between license.start_date and license.end_date),
    'events_expired', count(*) filter (where license.status = 'expired' or license.end_date < current_date),
    'events_suspended', count(*) filter (where license.status = 'suspended'),
    'orders_total', coalesce(sum(license.orders_used), 0),
    'devices_active', coalesce(sum((select count(*) from public.active_sessions session where session.festival_id = license.festival_id and session.last_seen >= now() - interval '5 minutes')), 0),
    'total_paid', coalesce(sum(license.total_paid), 0),
    'expiring_soon', count(*) filter (where license.status = 'active' and license.end_date between current_date and current_date + 7)
  ) end
  from public.event_licenses license;
$$;

create or replace function public.manager_dashboard()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
declare result jsonb;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  select private.manager_dashboard() into result; return result;
end;
$$;

create or replace function public.manager_list_events()
returns jsonb language sql stable security invoker set search_path = ''
as $$
  select case when not private.is_platform_admin() then null else coalesce(jsonb_agg(jsonb_build_object(
    'id', festival.id, 'name', festival.name, 'slug', festival.slug,
    'client_id', client.id, 'client_name', client.name, 'contact_name', client.contact_name,
    'email', client.email, 'phone', client.phone, 'client_notes', client.notes,
    'plan', license.plan, 'status', license.status, 'start_date', license.start_date,
    'end_date', license.end_date, 'purchased_days', license.purchased_days,
    'max_devices', license.max_devices, 'max_orders', license.max_orders,
    'orders_used', license.orders_used, 'daily_price', license.daily_price,
    'activation_fee', license.activation_fee, 'total_paid', license.total_paid,
    'payment_status', license.payment_status, 'internal_notes', license.internal_notes,
    'is_test', license.is_test,
    'active_devices', (select count(*) from public.active_sessions s where s.festival_id = festival.id and s.last_seen >= now() - interval '5 minutes'),
    'last_seen', (select max(s.last_seen) from public.active_sessions s where s.festival_id = festival.id)
  ) order by license.created_at desc), '[]'::jsonb) end
  from public.event_licenses license
  join public.festivals festival on festival.id = license.festival_id
  left join public.clients client on client.id = license.client_id;
$$;

create or replace function public.manager_get_event(p_festival_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
declare result jsonb;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  select jsonb_build_object(
    'event', row_to_json(event_row),
    'sessions', coalesce((select jsonb_agg(row_to_json(s) order by s.last_seen desc) from public.active_sessions s where s.festival_id = p_festival_id), '[]'::jsonb),
    'users', coalesce((select jsonb_agg(jsonb_build_object('auth_user_id', m.user_id, 'username', m.username, 'role', m.event_role, 'last_seen_at', m.last_seen_at)) from public.festival_members m where m.festival_id = p_festival_id), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(row_to_json(a) order by a.created_at desc) from (select action, details, created_at from public.license_audit_logs where festival_id = p_festival_id order by created_at desc limit 30) a), '[]'::jsonb)
  ) into result
  from (
    select f.id, f.name, f.slug, c.name client_name, c.contact_name, c.email, c.phone, c.notes client_notes,
           l.* from public.festivals f join public.event_licenses l on l.festival_id = f.id
           left join public.clients c on c.id = l.client_id where f.id = p_festival_id
  ) event_row;
  return result;
end;
$$;

create or replace function public.manager_create_event(p_data jsonb)
returns jsonb language plpgsql volatile security invoker set search_path = ''
as $$
declare
  created_client public.clients; created_festival public.festivals;
  selected_plan text := lower(coalesce(p_data->>'plan', 'starter'));
  selected_status text := lower(coalesce(p_data->>'status', 'draft'));
  start_on date := coalesce((p_data->>'start_date')::date, current_date);
  days_count integer := greatest(coalesce((p_data->>'purchased_days')::integer, 1), 1);
  end_on date; devices integer; orders_limit integer; price numeric;
  op_pin text := coalesce(p_data->>'operational_pin', '4826');
  stats_pin text := coalesce(p_data->>'stats_pin', '7391');
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  if selected_plan not in ('starter','pro','premium','enterprise') or selected_status not in ('active','suspended','expired','draft') then raise exception 'invalid plan or status'; end if;
  if op_pin !~ '^[0-9]{4,12}$' or stats_pin !~ '^[0-9]{4,12}$' or op_pin = stats_pin then raise exception 'invalid pins'; end if;
  end_on := coalesce((p_data->>'end_date')::date, start_on + days_count - 1);
  devices := case selected_plan when 'starter' then 5 when 'pro' then 15 when 'premium' then 30 else greatest(coalesce((p_data->>'max_devices')::integer, 1), 1) end;
  orders_limit := case selected_plan when 'starter' then 500 when 'pro' then 5000 when 'premium' then 15000 else greatest(coalesce((p_data->>'max_orders')::integer, 1), 1) end;
  price := case selected_plan when 'starter' then 15 when 'pro' then 25 when 'premium' then 40 else greatest(coalesce((p_data->>'daily_price')::numeric, 0), 0) end;

  insert into public.clients(name, contact_name, email, phone, notes)
  values (trim(p_data->>'client_name'), trim(coalesce(p_data->>'contact_name','')), lower(trim(coalesce(p_data->>'email',''))), trim(coalesce(p_data->>'phone','')), trim(coalesce(p_data->>'client_notes','')))
  returning * into created_client;

  insert into public.festivals(name, slug, pin_hash, stats_pin_hash)
  values (trim(p_data->>'event_name'), lower(trim(p_data->>'slug')),
          extensions.crypt(op_pin, extensions.gen_salt('bf', 11)),
          extensions.crypt(stats_pin, extensions.gen_salt('bf', 11)))
  returning * into created_festival;

  insert into public.event_licenses(festival_id, client_id, plan, status, start_date, end_date, purchased_days, max_devices, max_orders, daily_price, activation_fee, total_paid, payment_status, internal_notes, is_test)
  values (created_festival.id, created_client.id, selected_plan, selected_status, start_on, end_on, days_count, devices, orders_limit, price, 49,
          greatest(coalesce((p_data->>'total_paid')::numeric, 0), 0), coalesce(p_data->>'payment_status','unpaid'), trim(coalesce(p_data->>'internal_notes','')), coalesce((p_data->>'is_test')::boolean, false));
  insert into public.categories(festival_id, name, sort_order) values (created_festival.id, 'Cucina', 0), (created_festival.id, 'Bere', 1);
  insert into public.festival_members(festival_id, user_id, role, event_role, stats_access_until, username)
  values (created_festival.id, auth.uid(), 'owner', 'owner', 'infinity', 'admin@ordiva') on conflict do nothing;
  insert into public.license_audit_logs(festival_id, actor_user_id, action, details)
  values (created_festival.id, auth.uid(), 'event_created', p_data - 'operational_pin' - 'stats_pin');
  return jsonb_build_object('id', created_festival.id, 'name', created_festival.name, 'slug', created_festival.slug, 'operational_pin', op_pin, 'stats_pin', stats_pin);
end;
$$;

create or replace function public.manager_update_event(p_festival_id uuid, p_data jsonb)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
declare selected_plan text; devices integer; orders_limit integer; price numeric;
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  selected_plan := lower(p_data->>'plan');
  devices := case selected_plan when 'starter' then 5 when 'pro' then 15 when 'premium' then 30 else (p_data->>'max_devices')::integer end;
  orders_limit := case selected_plan when 'starter' then 500 when 'pro' then 5000 when 'premium' then 15000 else (p_data->>'max_orders')::integer end;
  price := case selected_plan when 'starter' then 15 when 'pro' then 25 when 'premium' then 40 else (p_data->>'daily_price')::numeric end;
  update public.festivals set name = trim(p_data->>'event_name') where id = p_festival_id;
  update public.clients c set name=trim(p_data->>'client_name'), contact_name=trim(coalesce(p_data->>'contact_name','')), email=lower(trim(coalesce(p_data->>'email',''))), phone=trim(coalesce(p_data->>'phone','')), notes=trim(coalesce(p_data->>'client_notes','')), updated_at=now()
  from public.event_licenses l where l.festival_id=p_festival_id and c.id=l.client_id;
  update public.event_licenses set plan=selected_plan, status=p_data->>'status', start_date=(p_data->>'start_date')::date, end_date=(p_data->>'end_date')::date, purchased_days=(p_data->>'purchased_days')::integer, max_devices=devices, max_orders=orders_limit, daily_price=price, total_paid=(p_data->>'total_paid')::numeric, payment_status=p_data->>'payment_status', internal_notes=trim(coalesce(p_data->>'internal_notes','')), updated_at=now()
  where festival_id=p_festival_id;
  insert into public.license_audit_logs(festival_id,actor_user_id,action,details) values(p_festival_id,auth.uid(),'event_updated',p_data);
end;
$$;

create or replace function public.manager_event_action(p_festival_id uuid, p_action text, p_value integer default null)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'admin access required'; end if;
  case p_action
    when 'suspend' then update public.event_licenses set status='suspended',updated_at=now() where festival_id=p_festival_id;
    when 'activate' then update public.event_licenses set status='active',updated_at=now() where festival_id=p_festival_id;
    when 'extend' then update public.event_licenses set end_date=end_date+greatest(p_value,1),purchased_days=purchased_days+greatest(p_value,1),updated_at=now() where festival_id=p_festival_id;
    when 'reset_sessions' then delete from public.active_sessions where festival_id=p_festival_id;
    when 'orders_3' then update public.event_licenses set max_orders=3,orders_used=0,updated_at=now() where festival_id=p_festival_id;
    when 'set_orders' then update public.event_licenses set orders_used=greatest(p_value,0),updated_at=now() where festival_id=p_festival_id;
    when 'expire' then update public.event_licenses set status='active',start_date=least(start_date,current_date-2),end_date=current_date-1,updated_at=now() where festival_id=p_festival_id;
    when 'device_1' then update public.event_licenses set max_devices=1,updated_at=now() where festival_id=p_festival_id;
    when 'reset_test' then update public.event_licenses set plan='starter',status='active',start_date=current_date,end_date=current_date+4,purchased_days=5,max_devices=5,max_orders=500,orders_used=(select count(*) from public.orders where festival_id=p_festival_id),daily_price=15,updated_at=now() where festival_id=p_festival_id;
    else raise exception 'invalid manager action';
  end case;
  insert into public.license_audit_logs(festival_id,actor_user_id,action,details) values(p_festival_id,auth.uid(),p_action,jsonb_build_object('value',p_value));
end;
$$;

-- Replace order creation with an atomic license counter and device assertion.
drop function if exists public.create_order(uuid, text, text, jsonb);
drop function if exists private.create_order(uuid, text, text, jsonb);

create function private.create_order(
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
    raise exception 'Hai raggiunto il limite di ordini del tuo piano. Contattaci per aumentare il limite.';
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

create function public.create_order(p_festival_id uuid,p_table_number text,p_notes text,p_items jsonb,p_device_id text)
returns bigint language sql volatile security invoker set search_path=''
as $$ select private.create_order(p_festival_id,p_table_number,p_notes,p_items,p_device_id) $$;

revoke all on all tables in schema public from anon, authenticated;
grant select(id,name,slug,timezone,created_at) on public.festivals to authenticated;
grant select on public.festival_members to authenticated;
grant select on public.profiles,public.clients,public.event_licenses,public.active_sessions,public.license_audit_logs to authenticated;
grant select,insert,update,delete on public.categories,public.products to authenticated;
grant select on public.orders,public.order_items to authenticated;
grant usage,select on all sequences in schema public to authenticated;

revoke all on function public.is_platform_admin() from public,anon;
revoke all on function public.register_device_session(uuid,text,text,text) from public,anon;
revoke all on function public.release_device_session(uuid,text) from public,anon;
revoke all on function public.get_my_festivals() from public,anon;
revoke all on function public.manager_dashboard() from public,anon;
revoke all on function public.manager_list_events() from public,anon;
revoke all on function public.manager_get_event(uuid) from public,anon;
revoke all on function public.manager_create_event(jsonb) from public,anon;
revoke all on function public.manager_update_event(uuid,jsonb) from public,anon;
revoke all on function public.manager_event_action(uuid,text,integer) from public,anon;
revoke all on function public.create_order(uuid,text,text,jsonb,text) from public,anon;
revoke all on function private.create_order(uuid,text,text,jsonb,text) from public,anon;

grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.register_device_session(uuid,text,text,text) to authenticated;
grant execute on function public.release_device_session(uuid,text) to authenticated;
grant execute on function public.get_my_festivals() to authenticated;
grant execute on function public.manager_dashboard() to authenticated;
grant execute on function public.manager_list_events() to authenticated;
grant execute on function public.manager_get_event(uuid) to authenticated;
grant execute on function public.manager_create_event(jsonb) to authenticated;
grant execute on function public.manager_update_event(uuid,jsonb) to authenticated;
grant execute on function public.manager_event_action(uuid,text,integer) to authenticated;
grant execute on function public.create_order(uuid,text,text,jsonb,text) to authenticated;
grant execute on function private.create_order(uuid,text,text,jsonb,text) to authenticated;

alter function public.manager_dashboard() security definer;
alter function public.manager_list_events() security definer;
alter function public.manager_get_event(uuid) security definer;
alter function public.manager_create_event(jsonb) security definer;
alter function public.manager_update_event(uuid,jsonb) security definer;
alter function public.manager_event_action(uuid,text,integer) security definer;
alter function public.release_device_session(uuid,text) security definer;

commit;
