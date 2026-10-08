-- 20260919215831  service_document_backup_foundation
-- Applied to Supabase project pwzpljitxamthgqllgtu


insert into public.permission_catalog(key, description) values
('service.view','View service jobs'),
('service.manage','Create and update service jobs'),
('documents.design','Manage document profile versions'),
('backup.manage','Create and review backup manifests')
on conflict (key) do update set description=excluded.description;

create table public.service_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  job_no text,
  customer_id uuid,
  status text not null default 'draft' check (status in ('draft','open','in_progress','waiting','completed','invoiced','cancelled')),
  opened_date date not null default current_date,
  promised_date date,
  vehicle_make text,
  vehicle_model text,
  vehicle_year text,
  plate_no text,
  chassis_no text,
  mileage numeric(18,2),
  complaint text,
  inspection_notes text,
  requested_work text,
  completed_work text,
  invoice_transaction_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(id, organization_id),
  unique(organization_id, job_no),
  foreign key (customer_id, organization_id) references public.parties(id, organization_id),
  foreign key (invoice_transaction_id, organization_id) references public.transactions(id, organization_id)
);

create table public.service_job_tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  service_job_id uuid not null,
  line_no integer not null,
  task_type text not null default 'service' check (task_type in ('service','labour','outside_work','inspection','additional')),
  description text not null,
  status text not null default 'pending' check (status in ('pending','in_progress','completed','cancelled')),
  estimated_amount numeric(18,2) not null default 0,
  actual_amount numeric(18,2) not null default 0,
  assigned_to uuid references auth.users(id),
  notes text,
  created_at timestamptz not null default now(),
  unique(organization_id, service_job_id, line_no),
  foreign key (service_job_id, organization_id) references public.service_jobs(id, organization_id) on delete cascade
);

create table public.document_profile_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_profile_id uuid not null,
  version integer not null,
  configuration jsonb not null,
  change_note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(organization_id, document_profile_id, version),
  foreign key (document_profile_id, organization_id) references public.document_profiles(id, organization_id) on delete cascade
);

create table public.backup_manifests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  backup_type text not null default 'manual' check (backup_type in ('manual','automatic','pre_restore')),
  status text not null default 'requested' check (status in ('requested','building','ready','failed','restored')),
  schema_version text not null,
  storage_path text,
  checksum text,
  manifest jsonb not null default '{}'::jsonb,
  error_message text,
  requested_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  restored_at timestamptz
);

create index service_jobs_org_status_idx on public.service_jobs(organization_id,status,opened_date desc);
create index service_jobs_customer_org_idx on public.service_jobs(customer_id,organization_id);
create index service_jobs_invoice_org_idx on public.service_jobs(invoice_transaction_id,organization_id);
create index service_job_tasks_job_org_idx on public.service_job_tasks(service_job_id,organization_id);
create index document_profile_versions_profile_org_idx on public.document_profile_versions(document_profile_id,organization_id,version desc);
create index backup_manifests_org_created_idx on public.backup_manifests(organization_id,created_at desc);

alter table public.service_jobs enable row level security;
alter table public.service_job_tasks enable row level security;
alter table public.document_profile_versions enable row level security;
alter table public.backup_manifests enable row level security;

create policy service_jobs_select on public.service_jobs for select to authenticated
using ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.view')));
create policy service_jobs_insert on public.service_jobs for insert to authenticated
with check ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')));
create policy service_jobs_update on public.service_jobs for update to authenticated
using ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')))
with check ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')));

create policy service_job_tasks_select on public.service_job_tasks for select to authenticated
using ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.view')));
create policy service_job_tasks_insert on public.service_job_tasks for insert to authenticated
with check ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')));
create policy service_job_tasks_update on public.service_job_tasks for update to authenticated
using ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')))
with check ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')));
create policy service_job_tasks_delete on public.service_job_tasks for delete to authenticated
using ((select private.is_org_member(organization_id, auth.uid())) and (select private.has_permission(organization_id, auth.uid(), 'service.manage')));

create policy document_profile_versions_select on public.document_profile_versions for select to authenticated
using ((select private.is_org_member(organization_id, auth.uid())));
create policy document_profile_versions_insert on public.document_profile_versions for insert to authenticated
with check ((select private.has_permission(organization_id, auth.uid(), 'documents.design')));

create policy backup_manifests_select on public.backup_manifests for select to authenticated
using ((select private.is_org_member(organization_id, auth.uid())));
create policy backup_manifests_insert on public.backup_manifests for insert to authenticated
with check ((select private.has_permission(organization_id, auth.uid(), 'backup.manage')));

grant select,insert,update on public.service_jobs to authenticated;
grant select,insert,update,delete on public.service_job_tasks to authenticated;
grant select,insert on public.document_profile_versions to authenticated;
grant select,insert on public.backup_manifests to authenticated;
;
