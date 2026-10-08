-- 20260921090310  backup_export_complete_entity_coverage
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.export_business_backup(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_backup_id uuid;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not (private.has_permission(p_org,v_uid,'backup.create') or private.has_permission(p_org,v_uid,'backup.manage')) then raise exception 'Permission denied'; end if;
  if not exists(select 1 from public.organizations where id=p_org) then raise exception 'Organization not found'; end if;

  insert into public.backup_manifests(organization_id,backup_type,status,schema_version,manifest,requested_by,completed_at)
  values(
    p_org,'manual','ready','2026-09-v2',
    jsonb_build_object(
      'format','business-platform-json',
      'includes_binary_files',false,
      'binary_files_external',true,
      'restore_supported',false,
      'entity_coverage','production-core'
    ),
    v_uid,now()
  ) returning id into v_backup_id;

  v_result:=jsonb_build_object(
    'format','business-platform-backup',
    'schema_version','2026-09-v2',
    'backup_id',v_backup_id,
    'created_at',now(),
    'includes_binary_files',false,
    'binary_files_external',true,
    'restore_supported',false,
    'organization',(select to_jsonb(o) from public.organizations o where o.id=p_org),
    'settings',(select to_jsonb(s) from public.organization_settings s where s.organization_id=p_org),
    'companies',coalesce((select jsonb_agg(to_jsonb(x)) from public.companies x where x.organization_id=p_org),'[]'::jsonb),
    'branches',coalesce((select jsonb_agg(to_jsonb(x)) from public.branches x where x.organization_id=p_org),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_roles x where x.organization_id=p_org),'[]'::jsonb),
    'role_permissions',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_role_permissions x where x.organization_id=p_org),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_members x where x.organization_id=p_org),'[]'::jsonb),
    'parties',coalesce((select jsonb_agg(to_jsonb(x)) from public.parties x where x.organization_id=p_org),'[]'::jsonb),
    'party_roles',coalesce((select jsonb_agg(to_jsonb(x)) from public.party_roles x where x.organization_id=p_org),'[]'::jsonb),
    'party_contacts',coalesce((select jsonb_agg(to_jsonb(x)) from public.party_contacts x where x.organization_id=p_org),'[]'::jsonb),
    'party_addresses',coalesce((select jsonb_agg(to_jsonb(x)) from public.party_addresses x where x.organization_id=p_org),'[]'::jsonb),
    'party_notes',coalesce((select jsonb_agg(to_jsonb(x)) from public.party_notes x where x.organization_id=p_org),'[]'::jsonb),
    'vehicles',coalesce((select jsonb_agg(to_jsonb(x)) from public.vehicles x where x.organization_id=p_org),'[]'::jsonb),
    'vehicle_mileage_history',coalesce((select jsonb_agg(to_jsonb(x)) from public.vehicle_mileage_history x where x.organization_id=p_org),'[]'::jsonb),
    'product_categories',coalesce((select jsonb_agg(to_jsonb(x)) from public.product_categories x where x.organization_id=p_org),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(to_jsonb(x)) from public.products x where x.organization_id=p_org),'[]'::jsonb),
    'product_prices',coalesce((select jsonb_agg(to_jsonb(x)) from public.product_prices x where x.organization_id=p_org),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(x)) from public.warehouses x where x.organization_id=p_org),'[]'::jsonb),
    'accounts',coalesce((select jsonb_agg(to_jsonb(x)) from public.accounts x where x.organization_id=p_org),'[]'::jsonb),
    'account_groups',coalesce((select jsonb_agg(to_jsonb(x)) from public.account_groups x where x.organization_id=p_org),'[]'::jsonb),
    'payment_methods',coalesce((select jsonb_agg(to_jsonb(x)) from public.payment_methods x where x.organization_id=p_org),'[]'::jsonb),
    'tax_codes',coalesce((select jsonb_agg(to_jsonb(x)) from public.tax_codes x where x.organization_id=p_org),'[]'::jsonb),
    'accounting_periods',coalesce((select jsonb_agg(to_jsonb(x)) from public.accounting_periods x where x.organization_id=p_org),'[]'::jsonb),
    'document_sequences',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_sequences x where x.organization_id=p_org),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(to_jsonb(x)) from public.transactions x where x.organization_id=p_org),'[]'::jsonb),
    'transaction_lines',coalesce((select jsonb_agg(to_jsonb(x)) from public.transaction_lines x where x.organization_id=p_org),'[]'::jsonb),
    'transaction_media',coalesce((select jsonb_agg(to_jsonb(x)) from public.transaction_media x where x.organization_id=p_org),'[]'::jsonb),
    'document_snapshots',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_snapshots x where x.organization_id=p_org),'[]'::jsonb),
    'journals',coalesce((select jsonb_agg(to_jsonb(x)) from public.journals x where x.organization_id=p_org),'[]'::jsonb),
    'journal_lines',coalesce((select jsonb_agg(to_jsonb(x)) from public.journal_lines x where x.organization_id=p_org),'[]'::jsonb),
    'stock_movements',coalesce((select jsonb_agg(to_jsonb(x)) from public.stock_movements x where x.organization_id=p_org),'[]'::jsonb),
    'stock_balances',coalesce((select jsonb_agg(to_jsonb(x)) from public.stock_balances x where x.organization_id=p_org),'[]'::jsonb),
    'open_items',coalesce((select jsonb_agg(to_jsonb(x)) from public.open_items x where x.organization_id=p_org),'[]'::jsonb),
    'allocations',coalesce((select jsonb_agg(to_jsonb(x)) from public.allocations x where x.organization_id=p_org),'[]'::jsonb),
    'service_jobs',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_jobs x where x.organization_id=p_org),'[]'::jsonb),
    'service_job_tasks',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_job_tasks x where x.organization_id=p_org),'[]'::jsonb),
    'service_job_items',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_job_items x where x.organization_id=p_org),'[]'::jsonb),
    'service_job_status_history',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_job_status_history x where x.organization_id=p_org),'[]'::jsonb),
    'document_profiles',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_profiles x where x.organization_id=p_org),'[]'::jsonb),
    'document_profile_versions',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_profile_versions x where x.organization_id=p_org),'[]'::jsonb),
    'attachments',coalesce((select jsonb_agg(to_jsonb(x)) from public.attachments x where x.organization_id=p_org),'[]'::jsonb),
    'voice_recordings',coalesce((select jsonb_agg(to_jsonb(x)) from public.voice_recordings x where x.organization_id=p_org),'[]'::jsonb),
    'audit_log',coalesce((select jsonb_agg(to_jsonb(x)) from public.audit_log x where x.organization_id=p_org),'[]'::jsonb)
  );

  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'backup.exported','backup',v_backup_id::text,jsonb_build_object('schema_version','2026-09-v2','includes_binary_files',false));
  return v_result;
end;
$$;;
