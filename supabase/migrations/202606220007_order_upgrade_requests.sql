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
