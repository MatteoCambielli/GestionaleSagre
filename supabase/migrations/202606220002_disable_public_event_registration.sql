-- Events are provisioned only by the authenticated platform Manager.
revoke execute on function public.register_festival(text,text,text,text) from authenticated;
revoke execute on function private.register_festival(text,text,text,text) from authenticated;
