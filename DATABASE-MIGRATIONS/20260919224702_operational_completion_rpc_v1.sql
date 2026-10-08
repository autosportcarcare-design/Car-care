-- 20260919224702  operational_completion_rpc_v1
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.seed_extended_sequences()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  insert into public.document_sequences(organization_id,sequence_key,prefix,padding)
  values
    (new.id,'job_card','JC',6),
    (new.id,'transfer','ST',6),
    (new.id,'delivery_note','DN',6),
    (new.id,'purchase_order','PO',6)
  on conflict (organization_id,sequence_key) do nothing;
  return new;
end;
$$;

drop trigger if exists organizations_seed_extended_sequences on public.organizations;
create trigger organizations_seed_extended_sequences
after insert on public.organizations
for each row execute function private.seed_extended_sequences();

insert into public.document_sequences(organization_id,sequence_key,prefix,padding)
select id,'job_card','JC',6 from public.organizations
on conflict (organization_id,sequence_key) do nothing;
insert into public.document_sequences(organization_id,sequence_key,prefix,padding)
select id,'transfer','ST',6 from public.organizations
on conflict (organization_id,sequence_key) do nothing;
insert into public.document_sequences(organization_id,sequence_key,prefix,padding)
select id,'delivery_note','DN',6 from public.organizations
on conflict (organization_id,sequence_key) do nothing;
insert into public.document_sequences(organization_id,sequence_key,prefix,padding)
select id,'purchase_order','PO',6 from public.organizations
on conflict (organization_id,sequence_key) do nothing;

create or replace function private.create_service_job(
  p_org uuid,
  p_customer uuid,
  p_vehicle_make text default null,
  p_vehicle_model text default null,
  p_vehicle_year text default null,
  p_plate_no text default null,
  p_chassis_no text default null,
  p_mileage numeric default null,
  p_complaint text default null,
  p_requested_work text default null,
  p_promised_date date default null
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_job uuid;
  v_job_no text;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'Permission denied'; end if;
  if p_customer is not null and not exists(
    select 1 from public.parties where id=p_customer and organization_id=p_org and status='active'
  ) then raise exception 'Customer not found in organization'; end if;
  v_job_no := private.allocate_document_no(p_org,'job_card');
  insert into public.service_jobs(
    organization_id,job_no,customer_id,status,opened_date,promised_date,
    vehicle_make,vehicle_model,vehicle_year,plate_no,chassis_no,mileage,
    complaint,requested_work,created_by,updated_by
  ) values(
    p_org,v_job_no,p_customer,'open',current_date,p_promised_date,
    nullif(trim(p_vehicle_make),''),nullif(trim(p_vehicle_model),''),nullif(trim(p_vehicle_year),''),
    nullif(trim(p_plate_no),''),nullif(trim(p_chassis_no),''),p_mileage,
    nullif(trim(p_complaint),''),nullif(trim(p_requested_work),''),v_uid,v_uid
  ) returning id into v_job;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'service_job.created','service_job',v_job::text,jsonb_build_object('job_no',v_job_no));
  return v_job;
end;
$$;

create or replace function public.create_service_job(
  p_org uuid,
  p_customer uuid,
  p_vehicle_make text default null,
  p_vehicle_model text default null,
  p_vehicle_year text default null,
  p_plate_no text default null,
  p_chassis_no text default null,
  p_mileage numeric default null,
  p_complaint text default null,
  p_requested_work text default null,
  p_promised_date date default null
) returns uuid
language sql
set search_path=''
as $$ select private.create_service_job($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11); $$;

create or replace function private.add_organization_member_by_email(
  p_org uuid,
  p_email text,
  p_role_name text
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_target uuid;
  v_role uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'Permission denied'; end if;
  if nullif(trim(p_email),'') is null then raise exception 'Email required'; end if;
  select id into v_target from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  if v_target is null then raise exception 'User must create an account before being added'; end if;
  select id into v_role from public.organization_roles where organization_id=p_org and lower(name)=lower(trim(p_role_name)) limit 1;
  if v_role is null then raise exception 'Role not found'; end if;
  insert into public.organization_members(organization_id,user_id,role_id,status)
  values(p_org,v_target,v_role,'active')
  on conflict (organization_id,user_id)
  do update set role_id=excluded.role_id,status='active',updated_at=now();
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'organization.member_upserted','organization_member',v_target::text,jsonb_build_object('email',lower(trim(p_email)),'role',p_role_name));
  return v_target;
end;
$$;

create or replace function public.add_organization_member_by_email(p_org uuid,p_email text,p_role_name text)
returns uuid
language sql
set search_path=''
as $$ select private.add_organization_member_by_email($1,$2,$3); $$;

create or replace function private.create_stock_transfer(
  p_org uuid,
  p_product uuid,
  p_from_warehouse uuid,
  p_to_warehouse uuid,
  p_quantity numeric,
  p_note text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_existing jsonb;
  v_doc text;
  v_tx uuid;
  v_product public.products%rowtype;
  v_from public.stock_balances%rowtype;
  v_to public.stock_balances%rowtype;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'stock.adjust') then raise exception 'Permission denied'; end if;
  if p_quantity is null or p_quantity<=0 then raise exception 'Transfer quantity must be positive'; end if;
  if p_from_warehouse=p_to_warehouse then raise exception 'Source and destination warehouses must differ'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'Idempotency key required'; end if;
  select result into v_existing from public.posting_requests where organization_id=p_org and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;
  select * into v_product from public.products where id=p_product and organization_id=p_org and status='active' for update;
  if not found or v_product.item_type<>'inventory' then raise exception 'Active inventory product required'; end if;
  if not exists(select 1 from public.warehouses where id=p_from_warehouse and organization_id=p_org and status='active') then raise exception 'Source warehouse not found'; end if;
  if not exists(select 1 from public.warehouses where id=p_to_warehouse and organization_id=p_org and status='active') then raise exception 'Destination warehouse not found'; end if;
  insert into public.stock_balances(organization_id,product_id,warehouse_id,quantity,average_cost)
  values(p_org,p_product,p_from_warehouse,0,v_product.average_cost) on conflict do nothing;
  insert into public.stock_balances(organization_id,product_id,warehouse_id,quantity,average_cost)
  values(p_org,p_product,p_to_warehouse,0,v_product.average_cost) on conflict do nothing;
  select * into v_from from public.stock_balances where organization_id=p_org and product_id=p_product and warehouse_id=p_from_warehouse for update;
  select * into v_to from public.stock_balances where organization_id=p_org and product_id=p_product and warehouse_id=p_to_warehouse for update;
  if v_from.quantity < p_quantity then raise exception 'Insufficient source stock'; end if;
  perform private.assert_period_open(p_org,current_date);
  v_doc := private.allocate_document_no(p_org,'transfer');
  insert into public.transactions(organization_id,transaction_type,document_no,sequence_key,transaction_date,status,currency,notes,created_by,posted_by,posted_at)
  select p_org,'transfer',v_doc,'transfer',current_date,'posted',currency,nullif(trim(p_note),''),v_uid,v_uid,now()
  from public.organization_settings where organization_id=p_org returning id into v_tx;
  update public.stock_balances set quantity=quantity-p_quantity,updated_at=now() where organization_id=p_org and product_id=p_product and warehouse_id=p_from_warehouse;
  update public.stock_balances set quantity=quantity+p_quantity,average_cost=v_from.average_cost,updated_at=now() where organization_id=p_org and product_id=p_product and warehouse_id=p_to_warehouse;
  insert into public.stock_movements(organization_id,transaction_id,product_id,warehouse_id,quantity_out,unit_cost,reason,created_by)
  values(p_org,v_tx,p_product,p_from_warehouse,p_quantity,v_from.average_cost,'warehouse transfer out',v_uid);
  insert into public.stock_movements(organization_id,transaction_id,product_id,warehouse_id,quantity_in,unit_cost,reason,created_by)
  values(p_org,v_tx,p_product,p_to_warehouse,p_quantity,v_from.average_cost,'warehouse transfer in',v_uid);
  v_result:=jsonb_build_object('transaction_id',v_tx,'document_no',v_doc,'status','posted','type','transfer');
  insert into public.posting_requests(organization_id,idempotency_key,transaction_id,result,created_by) values(p_org,p_idempotency_key,v_tx,v_result,v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'stock.transfer_posted','transaction',v_tx::text,v_result);
  return v_result;
end;
$$;

create or replace function public.create_stock_transfer(
  p_org uuid,p_product uuid,p_from_warehouse uuid,p_to_warehouse uuid,p_quantity numeric,p_note text,p_idempotency_key text
) returns jsonb
language sql
set search_path=''
as $$ select private.create_stock_transfer($1,$2,$3,$4,$5,$6,$7); $$;

create or replace function private.create_stock_adjustment(
  p_org uuid,
  p_product uuid,
  p_warehouse uuid,
  p_quantity_delta numeric,
  p_unit_cost numeric,
  p_note text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_existing jsonb;
  v_product public.products%rowtype;
  v_stock public.stock_balances%rowtype;
  v_settings public.organization_settings%rowtype;
  v_doc text;
  v_tx uuid;
  v_journal uuid;
  v_inventory uuid;
  v_loss uuid;
  v_gain uuid;
  v_cost numeric(18,6);
  v_value numeric(18,2);
  v_new_qty numeric(18,4);
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'stock.adjust') then raise exception 'Permission denied'; end if;
  if p_quantity_delta is null or p_quantity_delta=0 then raise exception 'Adjustment quantity cannot be zero'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'Idempotency key required'; end if;
  select result into v_existing from public.posting_requests where organization_id=p_org and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;
  select * into v_product from public.products where id=p_product and organization_id=p_org and status='active' for update;
  if not found or v_product.item_type<>'inventory' then raise exception 'Active inventory product required'; end if;
  if not exists(select 1 from public.warehouses where id=p_warehouse and organization_id=p_org and status='active') then raise exception 'Warehouse not found'; end if;
  select * into v_settings from public.organization_settings where organization_id=p_org;
  insert into public.stock_balances(organization_id,product_id,warehouse_id,quantity,average_cost)
  values(p_org,p_product,p_warehouse,0,v_product.average_cost) on conflict do nothing;
  select * into v_stock from public.stock_balances where organization_id=p_org and product_id=p_product and warehouse_id=p_warehouse for update;
  v_new_qty:=v_stock.quantity+p_quantity_delta;
  if v_new_qty<0 and coalesce(v_product.negative_stock_policy,v_settings.negative_stock_policy)='block' then raise exception 'Negative stock blocked'; end if;
  if v_new_qty<0 and coalesce(v_product.negative_stock_policy,v_settings.negative_stock_policy)='warn' and not private.has_permission(p_org,v_uid,'stock.negative_override') then raise exception 'Negative stock override permission denied'; end if;
  perform private.assert_period_open(p_org,current_date);
  v_cost:=case when p_unit_cost is not null and p_unit_cost>=0 then p_unit_cost else v_stock.average_cost end;
  v_value:=round(abs(p_quantity_delta)*v_cost,2);
  v_doc:=private.allocate_document_no(p_org,'stock_adjustment');
  insert into public.transactions(organization_id,transaction_type,document_no,sequence_key,transaction_date,status,currency,grand_total,notes,created_by,posted_by,posted_at)
  select p_org,'stock_adjustment',v_doc,'stock_adjustment',current_date,'posted',currency,v_value,nullif(trim(p_note),''),v_uid,v_uid,now()
  from public.organization_settings where organization_id=p_org returning id into v_tx;
  insert into public.transaction_lines(organization_id,transaction_id,line_no,product_id,warehouse_id,description,quantity,unit_price,line_net,line_total,unit_cost_snapshot)
  values(p_org,v_tx,1,p_product,p_warehouse,coalesce(nullif(trim(p_note),''),'Stock adjustment'),abs(p_quantity_delta),v_cost,v_value,v_value,v_cost);
  if p_quantity_delta>0 then
    update public.stock_balances set quantity=v_new_qty,average_cost=case when v_new_qty=0 then average_cost else round(((quantity*average_cost)+(p_quantity_delta*v_cost))/v_new_qty,6) end,updated_at=now() where organization_id=p_org and product_id=p_product and warehouse_id=p_warehouse;
    insert into public.stock_movements(organization_id,transaction_id,product_id,warehouse_id,quantity_in,unit_cost,reason,created_by) values(p_org,v_tx,p_product,p_warehouse,p_quantity_delta,v_cost,'stock adjustment gain',v_uid);
  else
    update public.stock_balances set quantity=v_new_qty,updated_at=now() where organization_id=p_org and product_id=p_product and warehouse_id=p_warehouse;
    insert into public.stock_movements(organization_id,transaction_id,product_id,warehouse_id,quantity_out,unit_cost,reason,created_by) values(p_org,v_tx,p_product,p_warehouse,abs(p_quantity_delta),v_cost,'stock adjustment loss',v_uid);
  end if;
  v_inventory:=private.system_account_id(p_org,'inventory');
  v_loss:=private.system_account_id(p_org,'operating_expense');
  v_gain:=private.system_account_id(p_org,'other_income');
  insert into public.journals(organization_id,transaction_id,journal_date,status,created_by) values(p_org,v_tx,current_date,'posted',v_uid) returning id into v_journal;
  if p_quantity_delta>0 then
    insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(p_org,v_journal,v_inventory,v_doc,v_value);
    insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(p_org,v_journal,v_gain,v_doc,v_value);
  else
    insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(p_org,v_journal,v_loss,v_doc,v_value);
    insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(p_org,v_journal,v_inventory,v_doc,v_value);
  end if;
  v_result:=jsonb_build_object('transaction_id',v_tx,'document_no',v_doc,'status','posted','type','stock_adjustment','quantity_delta',p_quantity_delta,'value',v_value);
  insert into public.posting_requests(organization_id,idempotency_key,transaction_id,result,created_by) values(p_org,p_idempotency_key,v_tx,v_result,v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(p_org,v_uid,'stock.adjustment_posted','transaction',v_tx::text,v_result);
  return v_result;
end;
$$;

create or replace function public.create_stock_adjustment(
  p_org uuid,p_product uuid,p_warehouse uuid,p_quantity_delta numeric,p_unit_cost numeric,p_note text,p_idempotency_key text
) returns jsonb
language sql
set search_path=''
as $$ select private.create_stock_adjustment($1,$2,$3,$4,$5,$6,$7); $$;

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
  values(p_org,'manual','ready','2026-09-v1',jsonb_build_object('format','business-platform-json','includes_binary_files',false),v_uid,now())
  returning id into v_backup_id;
  v_result:=jsonb_build_object(
    'format','business-platform-backup',
    'schema_version','2026-09-v1',
    'backup_id',v_backup_id,
    'created_at',now(),
    'organization',(select to_jsonb(o) from public.organizations o where o.id=p_org),
    'settings',(select to_jsonb(s) from public.organization_settings s where s.organization_id=p_org),
    'roles',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_roles x where x.organization_id=p_org),'[]'::jsonb),
    'role_permissions',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_role_permissions x where x.organization_id=p_org),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(to_jsonb(x)) from public.organization_members x where x.organization_id=p_org),'[]'::jsonb),
    'parties',coalesce((select jsonb_agg(to_jsonb(x)) from public.parties x where x.organization_id=p_org),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(to_jsonb(x)) from public.products x where x.organization_id=p_org),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(x)) from public.warehouses x where x.organization_id=p_org),'[]'::jsonb),
    'accounts',coalesce((select jsonb_agg(to_jsonb(x)) from public.accounts x where x.organization_id=p_org),'[]'::jsonb),
    'payment_methods',coalesce((select jsonb_agg(to_jsonb(x)) from public.payment_methods x where x.organization_id=p_org),'[]'::jsonb),
    'tax_codes',coalesce((select jsonb_agg(to_jsonb(x)) from public.tax_codes x where x.organization_id=p_org),'[]'::jsonb),
    'document_sequences',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_sequences x where x.organization_id=p_org),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(to_jsonb(x)) from public.transactions x where x.organization_id=p_org),'[]'::jsonb),
    'transaction_lines',coalesce((select jsonb_agg(to_jsonb(x)) from public.transaction_lines x where x.organization_id=p_org),'[]'::jsonb),
    'journals',coalesce((select jsonb_agg(to_jsonb(x)) from public.journals x where x.organization_id=p_org),'[]'::jsonb),
    'journal_lines',coalesce((select jsonb_agg(to_jsonb(x)) from public.journal_lines x where x.organization_id=p_org),'[]'::jsonb),
    'stock_movements',coalesce((select jsonb_agg(to_jsonb(x)) from public.stock_movements x where x.organization_id=p_org),'[]'::jsonb),
    'stock_balances',coalesce((select jsonb_agg(to_jsonb(x)) from public.stock_balances x where x.organization_id=p_org),'[]'::jsonb),
    'open_items',coalesce((select jsonb_agg(to_jsonb(x)) from public.open_items x where x.organization_id=p_org),'[]'::jsonb),
    'allocations',coalesce((select jsonb_agg(to_jsonb(x)) from public.allocations x where x.organization_id=p_org),'[]'::jsonb),
    'service_jobs',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_jobs x where x.organization_id=p_org),'[]'::jsonb),
    'service_job_tasks',coalesce((select jsonb_agg(to_jsonb(x)) from public.service_job_tasks x where x.organization_id=p_org),'[]'::jsonb),
    'document_profiles',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_profiles x where x.organization_id=p_org),'[]'::jsonb),
    'document_profile_versions',coalesce((select jsonb_agg(to_jsonb(x)) from public.document_profile_versions x where x.organization_id=p_org),'[]'::jsonb),
    'attachments',coalesce((select jsonb_agg(to_jsonb(x)) from public.attachments x where x.organization_id=p_org),'[]'::jsonb),
    'voice_recordings',coalesce((select jsonb_agg(to_jsonb(x)) from public.voice_recordings x where x.organization_id=p_org),'[]'::jsonb),
    'accounting_periods',coalesce((select jsonb_agg(to_jsonb(x)) from public.accounting_periods x where x.organization_id=p_org),'[]'::jsonb),
    'audit_log',coalesce((select jsonb_agg(to_jsonb(x)) from public.audit_log x where x.organization_id=p_org),'[]'::jsonb)
  );
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'backup.exported','backup',v_backup_id::text,jsonb_build_object('schema_version','2026-09-v1'));
  return v_result;
end;
$$;

create or replace function public.export_business_backup(p_org uuid)
returns jsonb
language sql
set search_path=''
as $$ select private.export_business_backup($1); $$;

revoke all on function public.create_service_job(uuid,uuid,text,text,text,text,text,numeric,text,text,date) from public,anon;
grant execute on function public.create_service_job(uuid,uuid,text,text,text,text,text,numeric,text,text,date) to authenticated;
revoke all on function public.add_organization_member_by_email(uuid,text,text) from public,anon;
grant execute on function public.add_organization_member_by_email(uuid,text,text) to authenticated;
revoke all on function public.create_stock_transfer(uuid,uuid,uuid,uuid,numeric,text,text) from public,anon;
grant execute on function public.create_stock_transfer(uuid,uuid,uuid,uuid,numeric,text,text) to authenticated;
revoke all on function public.create_stock_adjustment(uuid,uuid,uuid,numeric,numeric,text,text) from public,anon;
grant execute on function public.create_stock_adjustment(uuid,uuid,uuid,numeric,numeric,text,text) to authenticated;
revoke all on function public.export_business_backup(uuid) from public,anon;
grant execute on function public.export_business_backup(uuid) to authenticated;;
