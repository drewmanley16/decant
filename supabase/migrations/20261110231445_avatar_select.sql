-- Avatar uploads use upsert, which Storage only allows when the caller can also
-- SELECT the object. The avatars bucket had INSERT/UPDATE policies but no SELECT,
-- so every upload failed with a 400 (row-level security). Public URLs keep
-- working for everyone else because the bucket is public.
create policy "users read own avatars" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
