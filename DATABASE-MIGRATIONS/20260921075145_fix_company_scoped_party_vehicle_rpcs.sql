-- 20260921075145  fix_company_scoped_party_vehicle_rpcs
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.save_party_core(p_org uuid, p_id uuid, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid:=auth.uid(); v_old public.parties; v_new public.parties; v_code text; v_type text; v_name text; v_trn text; v_obt text; v_company uuid;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  v_type := coalesce(nullif(trim(p_data->>'party_type'),''),'customer');
  if v_type not in ('customer','supplier','both','other') then raise exception 'type must be customer, supplier, both or other'; end if;
  v_name := trim(coalesce(p_data->>'display_name', p_data->>'name', ''));
  if v_name = '' then v_name := trim(coalesce(p_data->>'legal_name','')); end if;
  if v_name = '' then raise exception 'display name or legal name is required'; end if;
  v_trn := nullif(regexp_replace(coalesce(p_data->>'tax_registration_no',''),'\s','','g'),'');
  if v_trn is not null and v_trn !~ '^[0-9]{15}$' then raise exception 'TRN must be exactly 15 digits'; end if;
  if nullif(p_data->>'email','') is not null and p_data->>'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email address is not valid'; end if;
  if coalesce((p_data->>'credit_limit')::numeric,0) < 0 then raise exception 'credit limit cannot be negative'; end if;
  if coalesce((p_data->>'credit_days')::int,0) < 0 then raise exception 'credit days cannot be negative'; end if;
  v_obt := nullif(p_data->>'opening_balance_type','');
  if coalesce((p_data->>'opening_balance')::numeric,0) <> 0 and v_obt is null then raise exception 'choose debit or credit for the opening balance'; end if;

  if p_id is null then
    if not private.has_permission(p_org,v_uid,'masters.create') then raise exception 'permission denied: create masters'; end if;
    v_company := nullif(p_data->>'company_id','')::uuid;
    if v_company is null then
      select id into v_company from public.companies where organization_id=p_org and is_default and status='active' order by created_at limit 1;
    end if;
    if v_company is null or not exists(select 1 from public.companies where id=v_company and organization_id=p_org and status='active') then
      raise exception 'company not found in organization';
    end if;
    v_code := nullif(trim(p_data->>'party_code'),'');
    if v_code is null then v_code := private.allocate_document_no(p_org, case when v_type='supplier' then 'supplier' else 'customer' end); end if;
    insert into public.parties(organization_id,company_id,party_type,name,party_code,reference_no,spr_no,legal_name,display_name,contact_person,
      mobile,alternate_mobile,whatsapp,telephone,email,alternate_email,tax_registration_no,address,address_line1,address_line2,area,city,emirate,
      country,postal_code,credit_limit,credit_days,opening_balance,opening_balance_type,notes,status,created_by,updated_by)
    values(p_org,v_company,v_type,v_name,v_code,nullif(p_data->>'reference_no',''),nullif(p_data->>'spr_no',''),nullif(p_data->>'legal_name',''),v_name,
      nullif(p_data->>'contact_person',''),nullif(p_data->>'mobile',''),nullif(p_data->>'alternate_mobile',''),nullif(p_data->>'whatsapp',''),
      nullif(p_data->>'telephone',''),nullif(p_data->>'email',''),nullif(p_data->>'alternate_email',''),v_trn,
      concat_ws(', ',nullif(p_data->>'address_line1',''),nullif(p_data->>'address_line2',''),nullif(p_data->>'area',''),nullif(p_data->>'city',''),nullif(p_data->>'emirate','')),
      nullif(p_data->>'address_line1',''),nullif(p_data->>'address_line2',''),nullif(p_data->>'area',''),nullif(p_data->>'city',''),
      nullif(p_data->>'emirate',''),coalesce(nullif(p_data->>'country',''),'United Arab Emirates'),nullif(p_data->>'postal_code',''),
      coalesce((p_data->>'credit_limit')::numeric,0),coalesce((p_data->>'credit_days')::int,0),coalesce((p_data->>'opening_balance')::numeric,0),
      v_obt,nullif(p_data->>'notes',''),'active',v_uid,v_uid)
    returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
    values(p_org,v_uid,'party.created','party',v_new.id::text,to_jsonb(v_new));
  else
    if not private.has_permission(p_org,v_uid,'masters.edit') then raise exception 'permission denied: edit masters'; end if;
    select * into v_old from public.parties where id=p_id and organization_id=p_org for update;
    if not found then raise exception 'customer/supplier not found in this organization'; end if;
    v_company := coalesce(nullif(p_data->>'company_id','')::uuid,v_old.company_id);
    if v_company <> v_old.company_id then raise exception 'moving a customer/supplier between companies is not supported; create a new company-scoped record'; end if;
    update public.parties set party_type=v_type,name=v_name,display_name=v_name,
      party_code=coalesce(nullif(trim(p_data->>'party_code'),''),v_old.party_code),reference_no=nullif(p_data->>'reference_no',''),spr_no=nullif(p_data->>'spr_no',''),legal_name=nullif(p_data->>'legal_name',''),
      contact_person=nullif(p_data->>'contact_person',''),mobile=nullif(p_data->>'mobile',''),alternate_mobile=nullif(p_data->>'alternate_mobile',''),whatsapp=nullif(p_data->>'whatsapp',''),telephone=nullif(p_data->>'telephone',''),email=nullif(p_data->>'email',''),alternate_email=nullif(p_data->>'alternate_email',''),tax_registration_no=v_trn,
      address=concat_ws(', ',nullif(p_data->>'address_line1',''),nullif(p_data->>'address_line2',''),nullif(p_data->>'area',''),nullif(p_data->>'city',''),nullif(p_data->>'emirate','')),
      address_line1=nullif(p_data->>'address_line1',''),address_line2=nullif(p_data->>'address_line2',''),area=nullif(p_data->>'area',''),city=nullif(p_data->>'city',''),emirate=nullif(p_data->>'emirate',''),country=coalesce(nullif(p_data->>'country',''),'United Arab Emirates'),postal_code=nullif(p_data->>'postal_code',''),credit_limit=coalesce((p_data->>'credit_limit')::numeric,0),credit_days=coalesce((p_data->>'credit_days')::int,0),opening_balance=coalesce((p_data->>'opening_balance')::numeric,0),opening_balance_type=v_obt,notes=nullif(p_data->>'notes',''),updated_by=v_uid,updated_at=now()
    where id=p_id returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
    values(p_org,v_uid,'party.updated','party',v_new.id::text,to_jsonb(v_old),to_jsonb(v_new));
  end if;
  return to_jsonb(v_new);
exception when unique_violation then raise exception 'code % is already used by another customer/supplier', v_code;
end;
$$;

create or replace function private.save_vehicle_core(p_org uuid, p_id uuid, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_old public.vehicles; v_new public.vehicles; v_cust uuid; v_code text; v_type text; v_company uuid; v_requested_company uuid;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  v_cust := nullif(p_data->>'customer_id','')::uuid;
  if v_cust is null then raise exception 'customer is required'; end if;
  select party_type,company_id into v_type,v_company from public.parties where id=v_cust and organization_id=p_org and status<>'archived';
  if not found then raise exception 'customer not found in this organization'; end if;
  if v_type not in ('customer','both') then raise exception 'selected party is not a customer'; end if;
  v_requested_company := nullif(p_data->>'company_id','')::uuid;
  if v_requested_company is not null and v_requested_company <> v_company then raise exception 'vehicle company must match customer company'; end if;
  if nullif(trim(p_data->>'plate_number'),'') is null and nullif(trim(p_data->>'chassis_vin'),'') is null then raise exception 'plate number or chassis/VIN is required'; end if;
  if coalesce((p_data->>'mileage')::numeric,0) < 0 then raise exception 'mileage cannot be negative'; end if;

  if p_id is null then
    if not private.has_permission(p_org,v_uid,'masters.create') then raise exception 'permission denied: create masters'; end if;
    v_code := coalesce(nullif(trim(p_data->>'vehicle_code'),''), private.allocate_document_no(p_org,'vehicle'));
    insert into public.vehicles(organization_id,company_id,customer_id,vehicle_code,make,model,variant,year,plate_number,registration_emirate,chassis_vin,engine_number,mileage,colour,registration_expiry,insurance_provider,insurance_expiry,notes,created_by,updated_by)
    values(p_org,v_company,v_cust,v_code,nullif(p_data->>'make',''),nullif(p_data->>'model',''),nullif(p_data->>'variant',''),nullif(p_data->>'year',''),upper(nullif(trim(p_data->>'plate_number'),'')),nullif(p_data->>'registration_emirate',''),upper(nullif(trim(p_data->>'chassis_vin'),'')),nullif(p_data->>'engine_number',''),(nullif(p_data->>'mileage',''))::numeric,nullif(p_data->>'colour',''),(nullif(p_data->>'registration_expiry',''))::date,nullif(p_data->>'insurance_provider',''),(nullif(p_data->>'insurance_expiry',''))::date,nullif(p_data->>'notes',''),v_uid,v_uid)
    returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(p_org,v_uid,'vehicle.created','vehicle',v_new.id::text,to_jsonb(v_new));
  else
    if not private.has_permission(p_org,v_uid,'masters.edit') then raise exception 'permission denied: edit masters'; end if;
    select * into v_old from public.vehicles where id=p_id and organization_id=p_org for update;
    if not found then raise exception 'vehicle not found in this organization'; end if;
    if v_old.company_id <> v_company then raise exception 'vehicle and customer must belong to the same company'; end if;
    update public.vehicles set customer_id=v_cust,vehicle_code=coalesce(nullif(trim(p_data->>'vehicle_code'),''),v_old.vehicle_code),make=nullif(p_data->>'make',''),model=nullif(p_data->>'model',''),variant=nullif(p_data->>'variant',''),year=nullif(p_data->>'year',''),plate_number=upper(nullif(trim(p_data->>'plate_number'),'')),registration_emirate=nullif(p_data->>'registration_emirate',''),chassis_vin=upper(nullif(trim(p_data->>'chassis_vin'),'')),engine_number=nullif(p_data->>'engine_number',''),mileage=(nullif(p_data->>'mileage',''))::numeric,colour=nullif(p_data->>'colour',''),registration_expiry=(nullif(p_data->>'registration_expiry',''))::date,insurance_provider=nullif(p_data->>'insurance_provider',''),insurance_expiry=(nullif(p_data->>'insurance_expiry',''))::date,notes=nullif(p_data->>'notes',''),updated_by=v_uid,updated_at=now()
    where id=p_id returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values) values(p_org,v_uid,'vehicle.updated','vehicle',p_id::text,to_jsonb(v_old),to_jsonb(v_new));
  end if;
  return to_jsonb(v_new);
exception when unique_violation then raise exception 'vehicle code % is already used', v_code;
end;
$$;;
