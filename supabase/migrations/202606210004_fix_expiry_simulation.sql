create or replace function public.manager_event_action(p_festival_id uuid, p_action text, p_value integer default null)
returns void language plpgsql volatile security definer set search_path = ''
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

revoke all on function public.manager_event_action(uuid,text,integer) from public,anon;
grant execute on function public.manager_event_action(uuid,text,integer) to authenticated;
