create or replace function public.update_product_image(
  p_product_id uuid,
  p_image_url text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Staff access is required';
  end if;
  if p_image_url is not null and (
    length(p_image_url) > 2800000
    or p_image_url !~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$'
  ) then
    raise exception 'Image must be a supported base64 image no larger than 2 MB';
  end if;

  update public.products
  set image_url = p_image_url
  where id = p_product_id and active;

  if not found then
    raise exception 'Product is unavailable';
  end if;
end;
$$;

revoke all on function public.update_product_image(uuid, text) from public, anon;
grant execute on function public.update_product_image(uuid, text) to authenticated;
