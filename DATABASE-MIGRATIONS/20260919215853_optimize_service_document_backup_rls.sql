-- 20260919215853  optimize_service_document_backup_rls
-- Applied to Supabase project pwzpljitxamthgqllgtu


create index if not exists service_jobs_created_by_idx on public.service_jobs(created_by);
create index if not exists service_jobs_updated_by_idx on public.service_jobs(updated_by);
create index if not exists service_job_tasks_assigned_to_idx on public.service_job_tasks(assigned_to);
create index if not exists document_profile_versions_created_by_idx on public.document_profile_versions(created_by);
create index if not exists backup_manifests_requested_by_idx on public.backup_manifests(requested_by);

drop policy if exists service_jobs_select on public.service_jobs;
drop policy if exists service_jobs_insert on public.service_jobs;
drop policy if exists service_jobs_update on public.service_jobs;
create policy service_jobs_select on public.service_jobs for select to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.view')));
create policy service_jobs_insert on public.service_jobs for insert to authenticated
with check ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')));
create policy service_jobs_update on public.service_jobs for update to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')))
with check ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')));

drop policy if exists service_job_tasks_select on public.service_job_tasks;
drop policy if exists service_job_tasks_insert on public.service_job_tasks;
drop policy if exists service_job_tasks_update on public.service_job_tasks;
drop policy if exists service_job_tasks_delete on public.service_job_tasks;
create policy service_job_tasks_select on public.service_job_tasks for select to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.view')));
create policy service_job_tasks_insert on public.service_job_tasks for insert to authenticated
with check ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')));
create policy service_job_tasks_update on public.service_job_tasks for update to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')))
with check ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')));
create policy service_job_tasks_delete on public.service_job_tasks for delete to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))) and (select private.has_permission(organization_id, (select auth.uid()), 'service.manage')));

drop policy if exists document_profile_versions_select on public.document_profile_versions;
drop policy if exists document_profile_versions_insert on public.document_profile_versions;
create policy document_profile_versions_select on public.document_profile_versions for select to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))));
create policy document_profile_versions_insert on public.document_profile_versions for insert to authenticated
with check ((select private.has_permission(organization_id, (select auth.uid()), 'documents.design')));

drop policy if exists backup_manifests_select on public.backup_manifests;
drop policy if exists backup_manifests_insert on public.backup_manifests;
create policy backup_manifests_select on public.backup_manifests for select to authenticated
using ((select private.is_org_member(organization_id, (select auth.uid()))));
create policy backup_manifests_insert on public.backup_manifests for insert to authenticated
with check ((select private.has_permission(organization_id, (select auth.uid()), 'backup.manage')));
;
