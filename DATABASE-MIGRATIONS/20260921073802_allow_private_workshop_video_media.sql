-- 20260921073802  allow_private_workshop_video_media
-- Applied to Supabase project pwzpljitxamthgqllgtu

update storage.buckets
set allowed_mime_types = array[
  'image/jpeg','image/png','image/webp','application/pdf','text/plain','text/csv',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'audio/webm','audio/mp4','audio/mpeg','audio/wav','audio/x-m4a',
  'video/mp4','video/quicktime','video/webm'
]
where id='business-media' and public=false;;
