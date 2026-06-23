create or replace function private.create_product(
  p_festival_id uuid,
  p_name text,
  p_price numeric,
  p_category text
)
returns public.products
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  created public.products;
begin
  if not private.is_festival_member(p_festival_id) then
    raise exception using errcode = '42501', message = 'Accesso evento non valido';
  end if;

  if char_length(trim(p_name)) not between 1 and 100
    or p_price is null
    or p_price < 0
    or p_price > 99999.99
    or char_length(trim(p_category)) not between 1 and 60 then
    raise exception using errcode = '22023', message = 'Dati prodotto non validi';
  end if;

  if not exists (
    select 1
    from public.categories
    where festival_id = p_festival_id
      and name = trim(p_category)
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

drop function if exists public.create_product(uuid, text, numeric, text);
create function public.create_product(
  p_festival_id uuid,
  p_name text,
  p_price numeric,
  p_category text
)
returns public.products
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.create_product(p_festival_id, p_name, p_price, p_category)
$$;

revoke all on function public.create_product(uuid, text, numeric, text) from public, anon;
grant execute on function public.create_product(uuid, text, numeric, text) to authenticated;
