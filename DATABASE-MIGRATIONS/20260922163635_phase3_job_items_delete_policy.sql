-- 20260922163635  phase3_job_items_delete_policy
-- Applied to Supabase project pwzpljitxamthgqllgtu

drop policy if exists service_job_items_delete on public.service_job_items;
create policy service_job_items_delete on public.service_job_items for delete to authenticated
  using (private.has_permission(organization_id, (select auth.uid()), 'service.manage'));
drop trigger if exists trg_audit_service_job_items on public.service_job_items;
create trigger trg_audit_service_job_items after insert or update or delete on public.service_job_items for each row execute function private.audit_row('service_job_item');;
