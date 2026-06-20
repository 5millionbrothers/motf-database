-- 업장·객실·상품 사진용 공개 Storage 버킷
-- 공개 URL로 사진을 표시하되 버킷 전체 파일 목록 조회는 허용하지 않습니다.
-- 업로드·수정·삭제는 로그인한 본인의 폴더에서만 가능합니다.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'catalog-images',
  'catalog-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'catalog_images_owner_insert'
  ) then
    create policy "catalog_images_owner_insert"
    on storage.objects for insert
    to authenticated
    with check (
      bucket_id = 'catalog-images'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'catalog_images_owner_update'
  ) then
    create policy "catalog_images_owner_update"
    on storage.objects for update
    to authenticated
    using (
      bucket_id = 'catalog-images'
      and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
      bucket_id = 'catalog-images'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'catalog_images_owner_delete'
  ) then
    create policy "catalog_images_owner_delete"
    on storage.objects for delete
    to authenticated
    using (
      bucket_id = 'catalog-images'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
  end if;
end
$$;
