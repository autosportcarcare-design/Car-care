-- 20260921072820  company_and_service_job_rpc_v2
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.create_company_v2(p_org uuid,p_name text,p_code text default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_company uuid; v_branch uuid; v_warehouse uuid; v_currency text; v_code text;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if not (private.has_permission(p_org,v_uid,'company.manage') or private.has_permission(p_org,v_uid,'settings.edit')) then raise exception 'permission denied'; end if;
  if length(trim(coalesce(p_name,'')))<1 then raise exception 'company name required'; end if;
  v_code:=upper(coalesce(nullif(regexp_replace(trim(coalesce(p_code,'')),'[^A-Za-z0-9]+','','g'),''),'CO'));
  select currency into v_currency from public.organization_settings where organization_id=p_org;
  insert into public.companies(organization_id,code,name,legal_name,country,currency,is_default,created_by)
  values(p_org,v_code,trim(p_name),trim(p_name),'United Arab Emirates',coalesce(v_currency,'AED'),false,v_uid) returning id into v_company;
  insert into public.branches(organization_id,company_id,code,name,is_default,created_by)
  values(p_org,v_company,'MAIN','Main Branch',true,v_uid) returning id into v_branch;
  insert into public.warehouses(organization_id,company_id,branch_id,code,name,status)
  values(p_org,v_company,v_branch,v_code||'-MAIN','Main Warehouse','active') returning id into v_warehouse;
  insert into public.audit_log(organization_id,company_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_company,v_uid,'company.created','company',v_company::text,jsonb_build_object('name',trim(p_name),'branch_id',v_branch,'warehouse_id',v_warehouse));
  return jsonb_build_object('company_id',v_company,'branch_id',v_branch,'warehouse_id',v_warehouse,'verified',true);
end $$;
revoke all on function private.create_company_v2(uuid,text,text) from public,anon;
grant execute on function private.create_company_v2(uuid,text,text) to authenticated;
create or replace function public.create_company_v2(p_org uuid,p_name text,p_code text default null)
returns jsonb language sql security invoker set search_path='' as $$ select private.create_company_v2($1,$2,$3); $$;
revoke all on function public.create_company_v2(uuid,text,text) from public,anon;
grant execute on function public.create_company_v2(uuid,text,text) to authenticated;

create or replace function private.create_service_job_v2(p_org uuid,p_company uuid,p_branch uuid,p_customer uuid,p_vehicle uuid,p_complaint text default null,p_requested_work text default null,p_promised_date date default null,p_mileage numeric default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_job uuid; v_job_no text; v_vehicle public.vehicles%rowtype; v_row public.service_jobs%rowtype;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'permission denied'; end if;
  if not exists(select 1 from public.companies where id=p_company and organization_id=p_org and status='active') then raise exception 'company not found'; end if;
  if p_branch is not null and not exists(select 1 from public.branches where id=p_branch and organization_id=p_org and company_id=p_company and status='active') then raise exception 'branch not found'; end if;
  if p_customer is null or not exists(select 1 from public.parties where id=p_customer and organization_id=p_org and company_id=p_company and status='active') then raise exception 'customer not found in company'; end if;
  if p_vehicle is not null then
    select * into v_vehicle from public.vehicles where id=p_vehicle and organization_id=p_org and company_id=p_company and customer_id=p_customer and status='active';
    if not found then raise exception 'vehicle not found for customer'; end if;
  end if;
  v_job_no:=private.allocate_document_no(p_org,'job_card');
  insert into public.service_jobs(organization_id,company_id,branch_id,job_no,customer_id,vehicle_id,status,opened_date,promised_date,vehicle_make,vehicle_model,vehicle_year,plate_no,chassis_no,mileage,complaint,requested_work,created_by,updated_by)
  values(p_org,p_company,p_branch,v_job_no,p_customer,p_vehicle,'open',current_date,p_promised_date,v_vehicle.make,v_vehicle.model,v_vehicle.year,v_vehicle.plate_number,v_vehicle.chassis_vin,coalesce(p_mileage,v_vehicle.mileage),nullif(trim(p_complaint),''),nullif(trim(p_requested_work),''),v_uid,v_uid)
  returning id into v_job;
  select * into v_row from public.service_jobs where id=v_job and organization_id=p_org;
  if not found or v_row.job_no<>v_job_no then raise exception 'service job verification failed'; end if;
  insert into public.audit_log(organization_id,company_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,p_company,v_uid,'service_job.created','service_job',v_job::text,jsonb_build_object('job_no',v_job_no,'vehicle_id',p_vehicle));
  return jsonb_build_object('service_job_id',v_job,'job_no',v_job_no,'status',v_row.status,'verified',true);
end $$;
revoke all on function private.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,text,text,date,numeric) from public,anon;
grant execute on function private.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,text,text,date,numeric) to authenticated;
create or replace function public.create_service_job_v2(p_org uuid,p_company uuid,p_branch uuid,p_customer uuid,p_vehicle uuid,p_complaint text default null,p_requested_work text default null,p_promised_date date default null,p_mileage numeric default null)
returns jsonb language sql security invoker set search_path='' as $$ select private.create_service_job_v2($1,$2,$3,$4,$5,$6,$7,$8,$9); $$;
revoke all on function public.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,text,text,date,numeric) from public,anon;
grant execute on function public.create_service_job_v2(uuid,uuid,uuid,uuid,uuid,text,text,date,numeric) to authenticated;;
