-- Group imported market SKUs into one storefront product while preserving each
-- offering row as the inventory and order unit. Safe to run more than once.

update public.offerings o
set detail_sections = coalesce(o.detail_sections, '{}'::jsonb) || jsonb_build_object(
      'productGroupKey',
      lower(regexp_replace(trim(o.name), '\s+', ' ', 'g')) || ':' ||
        lower(regexp_replace(trim(coalesce(o.detail_sections ->> 'manufacturer', '')), '\s+', ' ', 'g')),
      'variantLabel', coalesce(nullif(trim(o.unit), ''), '기본 구성')
    ),
    updated_at = now()
where o.detail_sections ->> 'importSource' =
  'google-sheet:11c1HDFn069x4ghtMJaAQZsVFa69zNTeevvOY-BwFN-I:gid-479454213';

