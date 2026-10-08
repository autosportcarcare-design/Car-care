-- 20260919225335  atomic_draft_and_historical_snapshots
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.get_org_operational_context(p_org uuid)
returns table(currency text,tax_enabled boolean,default_tax_rate numeric,prices_include_tax boolean,negative_stock_policy text,full_accounting_mode boolean)
language plpgsql
security definer
set search_path=''
as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.is_org_member(p_org,v_uid) then raise exception 'Permission denied'; end if;
  return query select s.currency,s.tax_enabled,s.default_tax_rate,s.prices_include_tax,s.negative_stock_policy,s.full_accounting_mode from public.organization_settings s where s.organization_id=p_org;
end;
$$;

create or replace function public.get_org_operational_context(p_org uuid)
returns table(currency text,tax_enabled boolean,default_tax_rate numeric,prices_include_tax boolean,negative_stock_policy text,full_accounting_mode boolean)
language sql
set search_path=''
as $$ select * from private.get_org_operational_context($1); $$;

create or replace function private.create_transaction_draft(p_org uuid,p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_type text:=nullif(trim(p_payload->>'transaction_type'),'');
  v_date date:=coalesce(nullif(p_payload->>'transaction_date','')::date,current_date);
  v_due date:=nullif(p_payload->>'due_date','')::date;
  v_party uuid:=nullif(p_payload->>'party_id','')::uuid;
  v_warehouse uuid:=nullif(p_payload->>'warehouse_id','')::uuid;
  v_payment uuid:=nullif(p_payload->>'payment_method_id','')::uuid;
  v_profile uuid:=nullif(p_payload->>'document_profile_id','')::uuid;
  v_currency text;
  v_tx uuid;
  v_line jsonb;
  v_idx integer:=0;
  v_product uuid;
  v_line_wh uuid;
  v_tax_id uuid;
  v_description text;
  v_qty numeric;
  v_rate numeric;
  v_discount numeric;
  v_tax public.tax_codes%rowtype;
  v_tax_enabled boolean;
  v_base numeric;
  v_net numeric;
  v_tax_amount numeric;
  v_total numeric;
  v_subtotal numeric:=0;
  v_discount_total numeric:=0;
  v_tax_total numeric:=0;
  v_grand numeric:=0;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'transaction.create') then raise exception 'Permission denied'; end if;
  if v_type is null or v_type not in ('sale','service_sale','mixed_sale','purchase','quotation','expense','income','receipt','payment','customer_refund','supplier_refund','credit_note','debit_note','stock_adjustment','capital','drawing','journal','transfer','opening_balance') then raise exception 'Unsupported transaction type'; end if;
  if p_payload->'lines' is null or jsonb_typeof(p_payload->'lines')<>'array' or jsonb_array_length(p_payload->'lines')=0 then raise exception 'At least one transaction line is required'; end if;
  select s.currency,s.tax_enabled into v_currency,v_tax_enabled from public.organization_settings s where s.organization_id=p_org;
  if v_currency is null then raise exception 'Organization settings not found'; end if;
  if v_party is not null and not exists(select 1 from public.parties where id=v_party and organization_id=p_org and status='active') then raise exception 'Party not found in organization'; end if;
  if v_warehouse is not null and not exists(select 1 from public.warehouses where id=v_warehouse and organization_id=p_org and status='active') then raise exception 'Warehouse not found in organization'; end if;
  if v_payment is not null and not exists(select 1 from public.payment_methods where id=v_payment and organization_id=p_org and status='active') then raise exception 'Payment method not found in organization'; end if;
  if v_profile is not null and not exists(select 1 from public.document_profiles where id=v_profile and organization_id=p_org and is_active) then raise exception 'Document profile not found in organization'; end if;
  insert into public.transactions(organization_id,transaction_type,transaction_date,due_date,party_id,warehouse_id,payment_method_id,status,currency,notes,negative_stock_confirmed,document_profile_id,created_by)
  values(p_org,v_type,v_date,v_due,v_party,v_warehouse,v_payment,'draft',v_currency,nullif(trim(p_payload->>'notes'),''),coalesce((p_payload->>'negative_stock_confirmed')::boolean,false),v_profile,v_uid)
  returning id into v_tx;
  for v_line in select value from jsonb_array_elements(p_payload->'lines') loop
    v_idx:=v_idx+1;
    v_product:=nullif(v_line->>'product_id','')::uuid;
    v_line_wh:=coalesce(nullif(v_line->>'warehouse_id','')::uuid,v_warehouse);
    v_tax_id:=nullif(v_line->>'tax_code_id','')::uuid;
    v_description:=trim(coalesce(v_line->>'description',''));
    v_qty:=coalesce(nullif(v_line->>'quantity','')::numeric,1);
    v_rate:=coalesce(nullif(v_line->>'unit_price','')::numeric,0);
    v_discount:=coalesce(nullif(v_line->>'discount_amount','')::numeric,0);
    if v_description='' then raise exception 'Line % description required',v_idx; end if;
    if v_qty<=0 then raise exception 'Line % quantity must be positive',v_idx; end if;
    if v_rate<0 or v_discount<0 then raise exception 'Line % rate/discount cannot be negative',v_idx; end if;
    if v_product is not null and not exists(select 1 from public.products where id=v_product and organization_id=p_org and status='active') then raise exception 'Line % product not found in organization',v_idx; end if;
    if v_line_wh is not null and not exists(select 1 from public.warehouses where id=v_line_wh and organization_id=p_org and status='active') then raise exception 'Line % warehouse not found in organization',v_idx; end if;
    v_base:=round((v_qty*v_rate-v_discount)::numeric,2);
    if v_base<0 then raise exception 'Line % discount exceeds value',v_idx; end if;
    v_tax:=null;
    if v_tax_enabled and v_tax_id is not null then
      select * into v_tax from public.tax_codes where id=v_tax_id and organization_id=p_org and status='active' and effective_from<=v_date and (effective_to is null or effective_to>=v_date);
      if not found then raise exception 'Line % tax code not effective',v_idx; end if;
    end if;
    if v_tax.id is not null and v_tax.inclusive and v_tax.rate>0 then
      v_total:=v_base; v_net:=round(v_base/(1+(v_tax.rate/100)),2); v_tax_amount:=round(v_total-v_net,2);
    else
      v_net:=v_base; v_tax_amount:=case when v_tax.id is not null then round(v_net*(v_tax.rate/100),2) else 0 end; v_total:=v_net+v_tax_amount;
    end if;
    insert into public.transaction_lines(organization_id,transaction_id,line_no,product_id,warehouse_id,description,quantity,unit_price,discount_amount,tax_code_id,tax_rate,tax_classification,tax_inclusive,input_tax_recoverable,line_net,line_tax,line_total)
    values(p_org,v_tx,v_idx,v_product,v_line_wh,v_description,v_qty,v_rate,v_discount,v_tax_id,coalesce(v_tax.rate,0),coalesce(v_tax.classification,'out_of_scope'),coalesce(v_tax.inclusive,false),case when v_tax.id is null then false else v_tax.input_recoverable_default end,v_net,v_tax_amount,v_total);
    v_subtotal:=v_subtotal+v_net; v_discount_total:=v_discount_total+v_discount; v_tax_total:=v_tax_total+v_tax_amount; v_grand:=v_grand+v_total;
  end loop;
  update public.transactions set subtotal=round(v_subtotal,2),discount_total=round(v_discount_total,2),tax_total=round(v_tax_total,2),grand_total=round(v_grand,2),balance_total=round(v_grand,2),updated_at=now() where id=v_tx;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(p_org,v_uid,'transaction.draft_created','transaction',v_tx::text,jsonb_build_object('transaction_type',v_type,'grand_total',round(v_grand,2),'lines',v_idx));
  return v_tx;
end;
$$;

create or replace function public.create_transaction_draft(p_org uuid,p_payload jsonb)
returns uuid
language sql
set search_path=''
as $$ select private.create_transaction_draft($1,$2); $$;

create or replace function private.capture_posting_snapshots()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_profile public.document_profiles%rowtype;
  v_profile_version public.document_profile_versions%rowtype;
  v_profile_type text;
begin
  if new.status='posted' and (tg_op='INSERT' or old.status is distinct from 'posted') then
    select jsonb_build_object('organization',to_jsonb(o),'settings',to_jsonb(s)) into new.organization_snapshot
    from public.organizations o left join public.organization_settings s on s.organization_id=o.id where o.id=new.organization_id;
    if new.party_id is not null then select to_jsonb(p) into new.party_snapshot from public.parties p where p.id=new.party_id and p.organization_id=new.organization_id; end if;
    if new.document_profile_id is null then
      v_profile_type:=case when new.transaction_type='service_sale' then 'service_invoice' when new.transaction_type in ('sale','mixed_sale') then 'invoice' when new.transaction_type='quotation' then 'quotation' when new.transaction_type in ('receipt','payment','expense') then 'voucher' else null end;
      if v_profile_type is not null then select * into v_profile from public.document_profiles where organization_id=new.organization_id and profile_type=v_profile_type and is_active order by version desc,created_at desc limit 1; end if;
      if v_profile.id is not null then new.document_profile_id:=v_profile.id; new.document_profile_version_id:=v_profile.active_version_id; end if;
    else
      select * into v_profile from public.document_profiles where id=new.document_profile_id and organization_id=new.organization_id;
      if v_profile.id is not null then new.document_profile_version_id:=coalesce(new.document_profile_version_id,v_profile.active_version_id); end if;
    end if;
    if new.document_profile_version_id is not null then
      select * into v_profile_version from public.document_profile_versions where id=new.document_profile_version_id and organization_id=new.organization_id;
      if v_profile_version.id is not null then new.document_profile_snapshot:=jsonb_build_object('profile',to_jsonb(v_profile),'version',to_jsonb(v_profile_version),'configuration',v_profile_version.configuration); end if;
    elsif v_profile.id is not null then
      new.document_profile_snapshot:=jsonb_build_object('profile',to_jsonb(v_profile),'configuration',v_profile.configuration);
    end if;
    new.organization_snapshot:=coalesce(new.organization_snapshot,'{}'::jsonb);
    new.party_snapshot:=coalesce(new.party_snapshot,'{}'::jsonb);
    new.document_profile_snapshot:=coalesce(new.document_profile_snapshot,'{}'::jsonb);
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_capture_posting_snapshots on public.transactions;
create trigger transactions_capture_posting_snapshots
before insert or update of status on public.transactions
for each row execute function private.capture_posting_snapshots();

revoke all on function public.get_org_operational_context(uuid) from public,anon;
grant execute on function public.get_org_operational_context(uuid) to authenticated;
revoke all on function public.create_transaction_draft(uuid,jsonb) from public,anon;
grant execute on function public.create_transaction_draft(uuid,jsonb) to authenticated;;
