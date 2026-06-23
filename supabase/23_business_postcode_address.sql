-- Store structured address data selected from the postcode/address search API.

alter table public.businesses
  add column if not exists postal_code text,
  add column if not exists address_detail text;

grant update (postal_code, address_detail, updated_at)
on public.businesses to authenticated;

grant select (postal_code)
on public.businesses to anon;

comment on column public.businesses.postal_code is 'Korean postcode selected from the address search API';
comment on column public.businesses.address_detail is 'Optional detailed address such as building, floor, or room';
