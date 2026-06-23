-- Repeated client submissions return the existing pending request without audit spam.
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

revoke all on function private.request_order_upgrade(uuid) from public, anon, authenticated;
grant execute on function private.request_order_upgrade(uuid) to authenticated;
