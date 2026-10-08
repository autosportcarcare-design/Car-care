-- 20260921080858  service_job_task_verified_rpc
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.add_service_job_task_v2(p_org uuid,p_company uuid,p_job uuid,p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_job public.service_jobs%rowtype;
  v_line int;
  v_task public.service_job_tasks%rowtype;
  v_type text:=coalesce(nullif(trim(p_data->>'task_type'),''),'service');
  v_desc text:=trim(coalesce(p_data->>'description',''));
  v_status text:=coalesce(nullif(trim(p_data->>'status'),''),'pending');
  v_est numeric:=coalesce(nullif(p_data->>'estimated_amount','')::numeric,0);
  v_actual numeric:=coalesce(nullif(p_data->>'actual_amount','')::numeric,0);
  v_sale numeric:=coalesce(nullif(p_data->>'sale_price','')::numeric,0);
  v_cost numeric:=coalesce(nullif(p_data->>'actual_cost','')::numeric,0);
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'Permission denied'; end if;
  if v_desc='' then raise exception 'Task description is required'; end if;
  if least(v_est,v_actual,v_sale,v_cost)<0 then raise exception 'Task amounts cannot be negative'; end if;

  select * into v_job from public.service_jobs where id=p_job and organization_id=p_org and company_id=p_company for update;
  if not found then raise exception 'Service job does not belong to company'; end if;
  if lower(v_job.status) in ('cancelled','delivered') then raise exception 'Cannot add tasks to a cancelled or delivered job'; end if;

  select coalesce(max(line_no),0)+1 into v_line from public.service_job_tasks where organization_id=p_org and service_job_id=p_job;
  insert into public.service_job_tasks(organization_id,company_id,service_job_id,line_no,task_type,category,description,status,estimated_amount,actual_amount,sale_price,actual_cost,notes)
  values(p_org,p_company,p_job,v_line,v_type,coalesce(nullif(p_data->>'category',''),v_type),v_desc,v_status,v_est,v_actual,v_sale,v_cost,nullif(p_data->>'notes',''))
  returning * into v_task;

  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'service_job.task_created','service_job_task',v_task.id::text,to_jsonb(v_task));

  select * into v_task from public.service_job_tasks where id=v_task.id and organization_id=p_org and company_id=p_company;
  if not found then raise exception 'Task read-back verification failed'; end if;
  return to_jsonb(v_task) || jsonb_build_object('verified',true);
end;
$$;

create or replace function public.add_service_job_task_v2(p_org uuid,p_company uuid,p_job uuid,p_data jsonb)
returns jsonb
language sql
set search_path=''
as $$ select private.add_service_job_task_v2($1,$2,$3,$4); $$;
revoke all on function public.add_service_job_task_v2(uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function public.add_service_job_task_v2(uuid,uuid,uuid,jsonb) to authenticated;;
