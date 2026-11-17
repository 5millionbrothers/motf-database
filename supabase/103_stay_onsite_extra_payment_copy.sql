-- Repair only the confirmed legacy sentence. Prices, approvals and history stay intact.
begin;

create function pg_temp.fix_stay_extra_payment_copy(value jsonb)
returns jsonb language plpgsql immutable strict as $$
begin
  case jsonb_typeof(value)
    when 'string' then
      return to_jsonb(replace(value #>> '{}',
        '금액은 현장에서 인원 확인 후 사이트를 통해 추가 결제하시면 됩니다',
        '금액은 현장에서 인원 확인 후 숙소 현장에서 직접 결제하시면 됩니다'));
    when 'array' then
      return coalesce((select jsonb_agg(pg_temp.fix_stay_extra_payment_copy(item) order by position)
        from jsonb_array_elements(value) with ordinality as items(item, position)), '[]'::jsonb);
    when 'object' then
      return coalesce((select jsonb_object_agg(key, pg_temp.fix_stay_extra_payment_copy(item))
        from jsonb_each(value) as fields(key, item)), '{}'::jsonb);
    else return value;
  end case;
end;
$$;

update public.businesses b
set amenity_details = pg_temp.fix_stay_extra_payment_copy(b.amenity_details), updated_at = now()
where b.business_type = 'stay'
  and b.amenity_details is distinct from pg_temp.fix_stay_extra_payment_copy(b.amenity_details);

update public.offerings o
set amenity_details = pg_temp.fix_stay_extra_payment_copy(o.amenity_details), updated_at = now()
where exists (select 1 from public.businesses b where b.id = o.business_id and b.business_type = 'stay')
  and o.amenity_details is distinct from pg_temp.fix_stay_extra_payment_copy(o.amenity_details);

-- Pending edits must not restore the old sentence after approval. Keep completed reviews unchanged.
update public.business_listing_review_requests r
set proposed_business = pg_temp.fix_stay_extra_payment_copy(r.proposed_business),
    proposed_offerings = pg_temp.fix_stay_extra_payment_copy(r.proposed_offerings), updated_at = now()
where r.status = 'pending'
  and exists (select 1 from public.businesses b where b.id = r.business_id and b.business_type = 'stay')
  and (r.proposed_business is distinct from pg_temp.fix_stay_extra_payment_copy(r.proposed_business)
    or r.proposed_offerings is distinct from pg_temp.fix_stay_extra_payment_copy(r.proposed_offerings));

drop function pg_temp.fix_stay_extra_payment_copy(jsonb);
commit;
