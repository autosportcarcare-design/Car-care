-- 20260921075309  fix_service_job_company_branch_scope
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.create_service_job(p_org uuid, p_customer uuid, p_vehicle_make text default null, p_vehicle_model text default null, p_vehicle_year text default null, p_plate_no text default null, p_chassis_no text default null, p_mileage numeric default null, p_complaint text default null, p_requested_work text default null, p_promised_date date default null)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_job uuid;
  v_job_no text;
  v_company uuid;
  v_branch uuid;
  v_party_type text;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'Permission denied'; end if;

  if p_customer is not null then
    select company_id,party_type into v_company,v_party_type
    from public.parties
    where id=p_customer and organization_id=p_org and status='active';
    if not found then raise exception 'Customer not found in organization'; end if;
    if v_party_type not in ('customer','both') then raise exception 'Selected party is not a customer'; end if;
  else
    select id into v_company from public.companies where organization_id=p_org and is_default and status='active' order by created_at limit 1;
  end if;

  if v_company is null then raise exception 'No active company is available for the service job'; end if;
  select id into v_branch from public.branches where organization_id=p_org and company_id=v_company and status='active' order by is_default desc,created_at limit 1;
  v_job_no := private.allocate_document_no(p_org,'job_card');

  insert into public.service_jobs(
    organization_id,company_id,branch_id,job_no,customer_id,status,opened_date,promised_date,
    vehicle_make,vehicle_model,vehicle_year,plate_no,chassis_no,mileage,
    complaint,requested_work,created_by,updated_by
  ) values(
    p_org,v_company,v_branch,v_job_no,p_customer,'open',current_date,p_promised_date,
    nullif(trim(p_vehicle_make),''),nullif(trim(p_vehicle_model),''),nullif(trim(p_vehicle_year),''),
    nullif(trim(p_plate_no),''),nullif(trim(p_chassis_no),''),p_mileage,
    nullif(trim(p_complaint),''),nullif(trim(p_requested_work),''),v_uid,v_uid
  ) returning id into v_job;

  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'service_job.created','service_job',v_job::text,jsonb_build_object('job_no',v_job_no,'company_id',v_company,'branch_id',v_branch));
  return v_job;
end;
$$;;
