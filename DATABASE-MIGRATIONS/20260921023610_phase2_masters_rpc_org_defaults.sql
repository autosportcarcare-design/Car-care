-- 20260921023610  phase2_masters_rpc_org_defaults
-- Applied to Supabase project pwzpljitxamthgqllgtu


-- ================= Org defaults: sequences, roles, accounts =================
create or replace function private.ensure_org_defaults(p_org uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_mgr uuid; v_acc uuid;
begin
  insert into public.document_sequences(organization_id,sequence_key,prefix,suffix,next_number,padding)
  select p_org,k,p,'',1,6 from (values
    ('invoice','INV-'),('quotation','QT-'),('purchase','PI-'),('receipt','RV-'),('payment','PV-'),('expense','EV-'),
    ('credit_note','CN-'),('debit_note','DN-'),('delivery_note','DO-'),('purchase_order','PO-'),('job_card','JC-'),
    ('stock_adjustment','SA-'),('journal','JV-'),('transfer','ST-'),('customer','CUS-'),('supplier','SUP-'),('vehicle','VEH-')) s(k,p)
  on conflict (organization_id,sequence_key) do nothing;
  update public.document_sequences set padding=6 where organization_id=p_org and padding<6;
  update public.document_sequences set suffix='' where organization_id=p_org and suffix is null;

  insert into public.organization_roles(organization_id,name,is_system) values (p_org,'Manager',true),(p_org,'Accountant',true)
  on conflict (organization_id,name) do nothing;
  select id into v_mgr from public.organization_roles where organization_id=p_org and name='Manager';
  select id into v_acc from public.organization_roles where organization_id=p_org and name='Accountant';
  if not exists (select 1 from public.organization_role_permissions where role_id=v_mgr) then
    insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select p_org,v_mgr,key from public.permission_catalog
    where key not in ('backup.restore','organization.admin','settings.edit','transaction.approve');
  end if;
  if not exists (select 1 from public.organization_role_permissions where role_id=v_acc) then
    insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select p_org,v_acc,key from public.permission_catalog
    where key in ('organization.view','masters.view','masters.create','masters.edit','transaction.view','transaction.create',
      'transaction.edit','transaction.post','transaction.void','transaction.print','transaction.export','accounting.view',
      'accounting.journal_create','stock.view','profit.view','service.view','audit.view','settings.view');
  end if;

  insert into public.accounts(organization_id,code,name,account_type,system_key) values
    (p_org,'3100','Drawings','equity','drawings'),
    (p_org,'5100','Direct Service Cost','cogs','direct_service_cost')
  on conflict do nothing;
end $$;

create or replace function private.org_defaults_after_settings() returns trigger
language plpgsql security definer set search_path='' as $$
begin perform private.ensure_org_defaults(new.organization_id); return null; end $$;
drop trigger if exists trg_org_defaults on public.organization_settings;
create trigger trg_org_defaults after insert on public.organization_settings
for each row execute function private.org_defaults_after_settings();

select private.ensure_org_defaults(id) from public.organizations;

-- default currency AED for new companies
create or replace function public.create_organization(p_name text, p_currency text default 'AED')
returns uuid language sql set search_path='' as $$ select private.create_organization($1,$2); $$;

-- ================= Companies the user belongs to =================
create or replace function private.my_organizations() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'name',o.name,'status',o.status,'role',r.name,
      'currency',s.currency,'legal_name',s.legal_name,
      'permissions',(select jsonb_agg(rp.permission_key) from public.organization_role_permissions rp where rp.role_id=m.role_id))
      order by o.created_at)
    from public.organization_members m
    join public.organizations o on o.id=m.organization_id
    join public.organization_roles r on r.id=m.role_id
    left join public.organization_settings s on s.organization_id=o.id
    where m.user_id=v_uid and m.status='active'),'[]'::jsonb);
end $$;
create or replace function public.my_organizations() returns jsonb language sql stable set search_path='' as $$ select private.my_organizations(); $$;

-- ================= Session audit (login / logout / company switch) =================
create or replace function private.log_session_event(p_org uuid, p_action text) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_action not in ('auth.login','auth.logout','company.switch') then raise exception 'invalid session action'; end if;
  if not private.is_org_member(p_org,v_uid) then raise exception 'not a member of this company'; end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,p_action,'session',v_uid::text,jsonb_build_object('at',now()));
end $$;
create or replace function public.log_session_event(p_org uuid, p_action text) returns void language sql set search_path='' as $$ select private.log_session_event($1,$2); $$;

-- ================= Customer / supplier master =================
create or replace function private.save_party(p_org uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_uid uuid:=auth.uid(); v_old public.parties; v_new public.parties; v_code text; v_type text; v_name text; v_trn text; v_obt text;
  function_txt text;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  v_type := coalesce(nullif(trim(p_data->>'party_type'),''),'customer');
  if v_type not in ('customer','supplier','both','other') then raise exception 'type must be customer, supplier or both'; end if;
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
    v_code := nullif(trim(p_data->>'party_code'),'');
    if v_code is null then
      v_code := private.allocate_document_no(p_org, case when v_type='supplier' then 'supplier' else 'customer' end);
    end if;
    insert into public.parties(organization_id,party_type,name,party_code,reference_no,spr_no,legal_name,display_name,contact_person,
      mobile,alternate_mobile,whatsapp,telephone,email,alternate_email,tax_registration_no,address,address_line1,address_line2,area,city,emirate,
      country,postal_code,credit_limit,credit_days,opening_balance,opening_balance_type,notes,status,created_by,updated_by)
    values(p_org,v_type,v_name,v_code,nullif(p_data->>'reference_no',''),nullif(p_data->>'spr_no',''),nullif(p_data->>'legal_name',''),v_name,
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
    if not found then raise exception 'customer/supplier not found in this company'; end if;
    update public.parties set party_type=v_type,name=v_name,display_name=v_name,
      party_code=coalesce(nullif(trim(p_data->>'party_code'),''),v_old.party_code),
      reference_no=nullif(p_data->>'reference_no',''),spr_no=nullif(p_data->>'spr_no',''),legal_name=nullif(p_data->>'legal_name',''),
      contact_person=nullif(p_data->>'contact_person',''),mobile=nullif(p_data->>'mobile',''),alternate_mobile=nullif(p_data->>'alternate_mobile',''),
      whatsapp=nullif(p_data->>'whatsapp',''),telephone=nullif(p_data->>'telephone',''),email=nullif(p_data->>'email',''),
      alternate_email=nullif(p_data->>'alternate_email',''),tax_registration_no=v_trn,
      address=concat_ws(', ',nullif(p_data->>'address_line1',''),nullif(p_data->>'address_line2',''),nullif(p_data->>'area',''),nullif(p_data->>'city',''),nullif(p_data->>'emirate','')),
      address_line1=nullif(p_data->>'address_line1',''),address_line2=nullif(p_data->>'address_line2',''),area=nullif(p_data->>'area',''),
      city=nullif(p_data->>'city',''),emirate=nullif(p_data->>'emirate',''),country=coalesce(nullif(p_data->>'country',''),'United Arab Emirates'),
      postal_code=nullif(p_data->>'postal_code',''),credit_limit=coalesce((p_data->>'credit_limit')::numeric,0),
      credit_days=coalesce((p_data->>'credit_days')::int,0),opening_balance=coalesce((p_data->>'opening_balance')::numeric,0),
      opening_balance_type=v_obt,notes=nullif(p_data->>'notes',''),updated_by=v_uid,updated_at=now()
    where id=p_id returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
    values(p_org,v_uid,'party.updated','party',v_new.id::text,to_jsonb(v_old),to_jsonb(v_new));
  end if;
  return to_jsonb(v_new);
exception when unique_violation then raise exception 'code % is already used by another customer/supplier', v_code;
end $$;
create or replace function public.save_party(p_org uuid, p_id uuid, p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.save_party($1,$2,$3); $$;

create or replace function private.set_party_archived(p_id uuid, p_archived boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_old public.parties; v_new public.parties;
begin
  select * into v_old from public.parties where id=p_id for update;
  if not found then raise exception 'customer/supplier not found'; end if;
  if not private.has_permission(v_old.organization_id,v_uid,'masters.edit') then raise exception 'permission denied: edit masters'; end if;
  update public.parties set status=case when p_archived then 'archived' else 'active' end,
    archived_at=case when p_archived then now() else null end, updated_by=v_uid, updated_at=now()
  where id=p_id returning * into v_new;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(v_new.organization_id,v_uid,case when p_archived then 'party.archived' else 'party.restored' end,'party',p_id::text,
    jsonb_build_object('status',v_old.status),jsonb_build_object('status',v_new.status));
  return to_jsonb(v_new);
end $$;
create or replace function public.set_party_archived(p_id uuid, p_archived boolean) returns jsonb language sql set search_path='' as $$ select private.set_party_archived($1,$2); $$;

-- ================= Vehicle master =================
create or replace function private.save_vehicle(p_org uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_old public.vehicles; v_new public.vehicles; v_cust uuid; v_code text; v_type text;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  v_cust := nullif(p_data->>'customer_id','')::uuid;
  if v_cust is null then raise exception 'customer is required'; end if;
  select party_type into v_type from public.parties where id=v_cust and organization_id=p_org and status<>'archived';
  if not found then raise exception 'customer not found in this company'; end if;
  if v_type not in ('customer','both') then raise exception 'selected party is not a customer'; end if;
  if nullif(trim(p_data->>'plate_number'),'') is null and nullif(trim(p_data->>'chassis_vin'),'') is null then
    raise exception 'plate number or chassis/VIN is required'; end if;
  if coalesce((p_data->>'mileage')::numeric,0) < 0 then raise exception 'mileage cannot be negative'; end if;

  if p_id is null then
    if not private.has_permission(p_org,v_uid,'masters.create') then raise exception 'permission denied: create masters'; end if;
    v_code := coalesce(nullif(trim(p_data->>'vehicle_code'),''), private.allocate_document_no(p_org,'vehicle'));
    insert into public.vehicles(organization_id,customer_id,vehicle_code,make,model,variant,year,plate_number,registration_emirate,
      chassis_vin,engine_number,mileage,colour,registration_expiry,insurance_provider,insurance_expiry,notes,created_by,updated_by)
    values(p_org,v_cust,v_code,nullif(p_data->>'make',''),nullif(p_data->>'model',''),nullif(p_data->>'variant',''),nullif(p_data->>'year',''),
      upper(nullif(trim(p_data->>'plate_number'),'')),nullif(p_data->>'registration_emirate',''),upper(nullif(trim(p_data->>'chassis_vin'),'')),
      nullif(p_data->>'engine_number',''),(nullif(p_data->>'mileage',''))::numeric,nullif(p_data->>'colour',''),
      (nullif(p_data->>'registration_expiry',''))::date,nullif(p_data->>'insurance_provider',''),(nullif(p_data->>'insurance_expiry',''))::date,
      nullif(p_data->>'notes',''),v_uid,v_uid)
    returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
    values(p_org,v_uid,'vehicle.created','vehicle',v_new.id::text,to_jsonb(v_new));
  else
    if not private.has_permission(p_org,v_uid,'masters.edit') then raise exception 'permission denied: edit masters'; end if;
    select * into v_old from public.vehicles where id=p_id and organization_id=p_org for update;
    if not found then raise exception 'vehicle not found in this company'; end if;
    update public.vehicles set customer_id=v_cust,vehicle_code=coalesce(nullif(trim(p_data->>'vehicle_code'),''),v_old.vehicle_code),
      make=nullif(p_data->>'make',''),model=nullif(p_data->>'model',''),variant=nullif(p_data->>'variant',''),year=nullif(p_data->>'year',''),
      plate_number=upper(nullif(trim(p_data->>'plate_number'),'')),registration_emirate=nullif(p_data->>'registration_emirate',''),
      chassis_vin=upper(nullif(trim(p_data->>'chassis_vin'),'')),engine_number=nullif(p_data->>'engine_number',''),
      mileage=(nullif(p_data->>'mileage',''))::numeric,colour=nullif(p_data->>'colour',''),
      registration_expiry=(nullif(p_data->>'registration_expiry',''))::date,insurance_provider=nullif(p_data->>'insurance_provider',''),
      insurance_expiry=(nullif(p_data->>'insurance_expiry',''))::date,notes=nullif(p_data->>'notes',''),updated_by=v_uid,updated_at=now()
    where id=p_id returning * into v_new;
    insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
    values(p_org,v_uid,'vehicle.updated','vehicle',p_id::text,to_jsonb(v_old),to_jsonb(v_new));
  end if;
  return to_jsonb(v_new);
exception when unique_violation then raise exception 'vehicle code % is already used', v_code;
end $$;
create or replace function public.save_vehicle(p_org uuid, p_id uuid, p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.save_vehicle($1,$2,$3); $$;

create or replace function private.set_vehicle_archived(p_id uuid, p_archived boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_new public.vehicles; v_org uuid; v_old text;
begin
  select organization_id,status into v_org,v_old from public.vehicles where id=p_id for update;
  if not found then raise exception 'vehicle not found'; end if;
  if not private.has_permission(v_org,v_uid,'masters.edit') then raise exception 'permission denied: edit masters'; end if;
  update public.vehicles set status=case when p_archived then 'archived' else 'active' end,updated_by=v_uid,updated_at=now()
  where id=p_id returning * into v_new;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(v_org,v_uid,case when p_archived then 'vehicle.archived' else 'vehicle.restored' end,'vehicle',p_id::text,
    jsonb_build_object('status',v_old),jsonb_build_object('status',v_new.status));
  return to_jsonb(v_new);
end $$;
create or replace function public.set_vehicle_archived(p_id uuid, p_archived boolean) returns jsonb language sql set search_path='' as $$ select private.set_vehicle_archived($1,$2); $$;

-- ================= Record history (visible to anyone who can view the master) =================
create or replace function private.record_history(p_org uuid, p_resource_type text, p_resource_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if p_resource_type not in ('party','vehicle') then raise exception 'history not available for %',p_resource_type; end if;
  if not private.has_permission(p_org,v_uid,'masters.view') then raise exception 'permission denied'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at',a.created_at,'action',a.action,'actor',u.email,
      'previous',a.previous_values,'new',a.new_values) order by a.created_at desc)
    from public.audit_log a left join auth.users u on u.id=a.actor_id
    where a.organization_id=p_org and a.resource_type=p_resource_type and a.resource_id=p_resource_id::text),'[]'::jsonb);
end $$;
create or replace function public.record_history(p_org uuid, p_resource_type text, p_resource_id uuid) returns jsonb language sql stable set search_path='' as $$ select private.record_history($1,$2,$3); $$;

-- ================= Grants: signed-in users only =================
revoke all on function public.my_organizations() from public, anon;
revoke all on function public.log_session_event(uuid,text) from public, anon;
revoke all on function public.save_party(uuid,uuid,jsonb) from public, anon;
revoke all on function public.set_party_archived(uuid,boolean) from public, anon;
revoke all on function public.save_vehicle(uuid,uuid,jsonb) from public, anon;
revoke all on function public.set_vehicle_archived(uuid,boolean) from public, anon;
revoke all on function public.record_history(uuid,text,uuid) from public, anon;
grant execute on function public.my_organizations(), public.log_session_event(uuid,text), public.save_party(uuid,uuid,jsonb),
  public.set_party_archived(uuid,boolean), public.save_vehicle(uuid,uuid,jsonb), public.set_vehicle_archived(uuid,boolean),
  public.record_history(uuid,text,uuid), public.create_organization(text,text) to authenticated;
;
