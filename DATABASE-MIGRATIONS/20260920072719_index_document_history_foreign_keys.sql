-- 20260920072719  index_document_history_foreign_keys
-- Applied to Supabase project pwzpljitxamthgqllgtu

create index if not exists document_profiles_active_version_org_idx on public.document_profiles(active_version_id,organization_id); create index if not exists document_profiles_reference_attachment_org_idx on public.document_profiles(reference_attachment_id,organization_id); create index if not exists organization_settings_history_changed_by_idx on public.organization_settings_history(changed_by); create index if not exists transactions_document_profile_org_idx on public.transactions(document_profile_id,organization_id); create index if not exists transactions_document_profile_version_org_idx on public.transactions(document_profile_version_id,organization_id);;
