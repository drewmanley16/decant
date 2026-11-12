-- Label uploads use upsert, which needs SELECT on the object as well as INSERT.
-- Without it every label upload failed, so scan photos and scan history were never saved.
create policy "users read own labels" on storage.objects
  for select to authenticated
  using (bucket_id = 'labels' and (storage.foldername(name))[1] = auth.uid()::text);
