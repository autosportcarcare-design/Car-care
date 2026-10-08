-- 20260921023715  phase2_fix_create_organization_order
-- Applied to Supabase project pwzpljitxamthgqllgtu


drop trigger if exists trg_org_defaults on public.organization_settings;

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
  -- normalise unused sequences only (never renumber a sequence already in use)
  update public.document_sequences set prefix='DO-' where organization_id=p_org and sequence_key='delivery_note' and next_number=1;
  update public.document_sequences set prefix=prefix||'-' where organization_id=p_org and right(prefix,1)<>'-' and next_number=1;
  update public.document_sequences set padding=6 where organization_id=p_org and padding<6 and next_number=1;
  update public.document_sequences set suffix='' where organization_id=p_org and suffix is null;

  insert into public.organization_roles(organization_id,name,is_system) values (p_org,'Manager',true),(p_org,'Accountant',true)
  on conflict (organization_id,name) do nothing;
  select id into v_mgr from public.organization_roles where organization_id=p_org and name='Manager';
  select id into v_acc from public.organization_roles where organization_id=p_org and name='Accountant';
  if not exists (select 1 from public.organization_role_permissions where role_id=v_mgr) then
    insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select p_org,v_mgr,key from public.permission_catalog where key not in ('backup.restore','organization.admin','settings.edit','transaction.approve');
  end if;
  if not exists (select 1 from public.organization_role_permissions where role_id=v_acc) then
    insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select p_org,v_acc,key from public.permission_catalog
    where key in ('organization.view','masters.view','masters.create','masters.edit','transaction.view','transaction.create',
      'transaction.edit','transaction.post','transaction.void','transaction.print','transaction.export','accounting.view',
      'accounting.journal_create','stock.view','profit.view','service.view','audit.view','settings.view');
  end if;
  insert into public.accounts(organization_id,code,name,account_type,system_key) values
    (p_org,'3100','Drawings','equity','drawings'),(p_org,'5100','Direct Service Cost','cogs','direct_service_cost')
  on conflict do nothing;
end $$;

create or replace function private.create_organization(p_name text, p_currency text default 'AED')
returns uuid language plpgsql security definer set search_path='' as $function$
declare v_uid uuid := auth.uid(); v_org uuid; v_owner_role uuid; v_admin_role uuid; v_staff_role uuid; v_cash uuid; v_bank uuid;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if length(trim(coalesce(p_name,''))) < 1 then raise exception 'company name required'; end if;
  if length(trim(coalesce(p_currency,''))) <> 3 then raise exception 'currency must be a 3-letter code'; end if;
  insert into public.organizations(name,created_by) values(trim(p_name),v_uid) returning id into v_org;
  insert into public.organization_roles(organization_id,name,is_system) values (v_org,'Owner',true),(v_org,'Admin',true),(v_org,'Staff',true);
  select id into v_owner_role from public.organization_roles where organization_id=v_org and name='Owner';
  select id into v_admin_role from public.organization_roles where organization_id=v_org and name='Admin';
  select id into v_staff_role from public.organization_roles where organization_id=v_org and name='Staff';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_owner_role,key from public.permission_catalog;
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_admin_role,key from public.permission_catalog where key <> 'backup.restore';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_staff_role,key from public.permission_catalog where key in ('organization.view','masters.view','masters.create','transaction.view','transaction.create','transaction.edit','transaction.print','stock.view','service.view','service.manage');
  insert into public.organization_members(organization_id,user_id,role_id,status) values(v_org,v_uid,v_owner_role,'active');
  insert into public.organization_settings(organization_id,currency,updated_by) values(v_org,upper(trim(p_currency)),v_uid);
  insert into public.accounts(organization_id,code,name,account_type,system_key) values
    (v_org,'1000','Cash','asset','cash'),(v_org,'1010','Bank','asset','bank'),(v_org,'1100','Accounts Receivable','asset','accounts_receivable'),
    (v_org,'1200','Inventory','asset','inventory'),(v_org,'1300','Input VAT','asset','input_tax'),(v_org,'2000','Accounts Payable','liability','accounts_payable'),
    (v_org,'2100','Output VAT','liability','output_tax'),(v_org,'3000','Capital','equity','equity'),(v_org,'4000','Trading Sales','income','sales_revenue'),
    (v_org,'4100','Service Revenue','income','service_revenue'),(v_org,'4200','Other Income','income','other_income'),(v_org,'5000','Cost of Goods Sold','cogs','cogs'),(v_org,'6000','Operating Expense','expense','operating_expense');
  select id into v_cash from public.accounts where organization_id=v_org and system_key='cash';
  select id into v_bank from public.accounts where organization_id=v_org and system_key='bank';
  insert into public.payment_methods(organization_id,name,account_id) values(v_org,'Cash',v_cash),(v_org,'Bank',v_bank);
  insert into public.warehouses(organization_id,code,name) values(v_org,'MAIN','Main Warehouse');
  perform private.ensure_org_defaults(v_org);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
    values(v_org,v_uid,'organization.created','organization',v_org::text,jsonb_build_object('name',trim(p_name)));
  return v_org;
end $function$;

select private.ensure_org_defaults(id) from public.organizations;
;
