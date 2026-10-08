-- 20260921075520  service_job_v2_vehicle_link
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.create_service_job_v2(
  p_org uuid,
  p_company uuid,
  p_branch uuid,
  p_customer uuid,
  p_vehicle uuid,
  p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_branch uuid:=p_branch;
  v_job_no text;
  v_job public.service_jobs%rowtype;
  v_party public.parties%rowtype;
  v_vehicle public.vehicles%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'Permission denied'; end if;
  if p_company is null or not exists(select 1 from public.companies where id=p_company and organization_id=p_org and status='active') then raise exception 'Active company required'; end if;
  if v_branch is null then select id into v_branch from public.branches where organization_id=p_org and company_id=p_company and status='active' order by is_default desc,created_at limit 1; end if;
  if v_branch is not null and not exists(select 1 from public.branches where id=v_branch and organization_id=p_org and company_id=p_company and status='active') then raise exception 'Branch does not belong to company'; end if;
  select * into v_party from public.parties where id=p_customer and organization_id=p_org and company_id=p_company and status='active';
  if not found or v_party.party_type not in ('customer','both') then raise exception 'Customer does not belong to company'; end if;
  select * into v_vehicle from public.vehicles where id=p_vehicle and organization_id=p_org and company_id=p_company and customer_id=p_customer and status='active';
  if not found then raise exception 'Vehicle does not belong to selected customer/company'; end if;
  v_job_no:=private.allocate_document_no(p_org,'job_card');
  insert into public.service_jobs(
    organization_id,company_id,branch_id,job_no,customer_id,vehicle_id,status,opened_date,promised_date,
    vehicle_make,vehicle_model,vehicle_year,plate_no,chassis_no,mileage,customer_phone,
    complaint,inspection_notes,requested_work,completed_work,notes,created_by,updated_by
  ) values(
    p_org,p_company,v_branch,v_job_no,p_customer,p_vehicle,'open',coalesce(nullif(p_data->>'opened_date','')::date,current_date),nullif(p_data->>'promised_date','')::date,
    v_vehicle.make,v_vehicle.model,v_vehicle.year,v_vehicle.plate_number,v_vehicle.chassis_vin,coalesce(nullif(p_data->>'mileage','')::numeric,v_vehicle.mileage),coalesce(v_party.mobile,v_party.phone),
    nullif(trim(p_data->>'complaint'),''),nullif(trim(p_data->>'inspection_notes'),''),nullif(trim(p_data->>'requested_work'),''),nullif(trim(p_data->>'completed_work'),''),nullif(trim(p_data->>'notes'),''),v_uid,v_uid
  ) returning * into v_job;
  insert into public.service_job_status_history(organization_id,company_id,service_job_id,from_status,to_status,note,changed_by)
  values(p_org,p_company,v_job.id,null,'open','Job card created',v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'service_job.created','service_job',v_job.id::text,to_jsonb(v_job));
  return to_jsonb(v_job);
end;
$$;

create or replace function public.create_service_job_v2(p_org uuid,p_company uuid,p_branch uuid,p_customer uuid,p_vehicle uuid,p_data jsonb)
returns jsonb
language sql
set search_path=''
as $$ select private.create_service_job_v2($1,$2,$3,$4,$5,$6); $$;

revoke all on function public.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function public.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,jsonb) to authenticated;;
