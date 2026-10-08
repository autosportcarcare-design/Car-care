-- 20260919075003  v2_atomic_posting_engine
-- Applied to Supabase project pwzpljitxamthgqllgtu

alter table public.transactions add column negative_stock_confirmed boolean not null default false;

create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'open' check (status in ('open','locked')),
  locked_by uuid references auth.users(id),
  locked_at timestamptz,
  unique (organization_id, name),
  check (end_date >= start_date)
);
create index accounting_periods_org_dates_idx on public.accounting_periods(organization_id,start_date,end_date,status);
alter table public.accounting_periods enable row level security;
create policy periods_select on public.accounting_periods for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy periods_write on public.accounting_periods for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
grant select,insert,update,delete on public.accounting_periods to authenticated;

alter table public.journals drop constraint journals_transaction_id_key;
create unique index journals_original_transaction_unique on public.journals(transaction_id) where reversal_of is null;

create or replace function private.system_account_id(p_org uuid,p_key text)
returns uuid language sql stable security definer set search_path='' as $$
  select id from public.accounts where organization_id=p_org and system_key=p_key and status='active' limit 1;
$$;
revoke all on function private.system_account_id(uuid,text) from public;
grant execute on function private.system_account_id(uuid,text) to authenticated;

create or replace function private.sequence_key_for(p_type text)
returns text language sql immutable set search_path='' as $$
  select case
    when p_type in ('sale','service_sale','mixed_sale') then 'invoice'
    when p_type='quotation' then 'quotation'
    when p_type='purchase' then 'purchase'
    when p_type='receipt' then 'receipt'
    when p_type='payment' then 'payment'
    when p_type='expense' then 'expense'
    when p_type='credit_note' then 'credit_note'
    when p_type='debit_note' then 'debit_note'
    when p_type='journal' then 'journal'
    when p_type='stock_adjustment' then 'stock_adjustment'
    else p_type
  end;
$$;

create or replace function private.allocate_document_no(p_org uuid,p_type text)
returns text language plpgsql security definer set search_path='' as $$
declare v_key text := private.sequence_key_for(p_type); v_no text;
begin
  update public.document_sequences
     set next_number=next_number+1, updated_at=now()
   where organization_id=p_org and sequence_key=v_key
   returning prefix || lpad((next_number-1)::text,padding,'0') || suffix into v_no;
  if v_no is null then raise exception 'No numbering sequence configured for %',v_key; end if;
  return v_no;
end $$;
revoke all on function private.allocate_document_no(uuid,text) from public;
grant execute on function private.allocate_document_no(uuid,text) to authenticated;

create or replace function private.assert_period_open(p_org uuid,p_date date)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if exists(select 1 from public.accounting_periods where organization_id=p_org and status='locked' and p_date between start_date and end_date) then
    raise exception 'Accounting period is locked for %',p_date;
  end if;
end $$;
revoke all on function private.assert_period_open(uuid,date) from public;
grant execute on function private.assert_period_open(uuid,date) to authenticated;

create or replace function public.create_organization(p_name text, p_currency text default 'USD')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_org uuid; v_owner_role uuid; v_admin_role uuid; v_staff_role uuid; v_cash uuid; v_bank uuid;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if length(trim(p_name)) < 1 then raise exception 'organization name required'; end if;
  if length(trim(p_currency)) <> 3 then raise exception 'currency must be a 3-letter code'; end if;
  insert into public.organizations(name,created_by) values(trim(p_name),v_uid) returning id into v_org;
  insert into public.organization_roles(organization_id,name,is_system) values (v_org,'Owner',true),(v_org,'Admin',true),(v_org,'Staff',true);
  select id into v_owner_role from public.organization_roles where organization_id=v_org and name='Owner';
  select id into v_admin_role from public.organization_roles where organization_id=v_org and name='Admin';
  select id into v_staff_role from public.organization_roles where organization_id=v_org and name='Staff';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_owner_role,key from public.permission_catalog;
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_admin_role,key from public.permission_catalog where key <> 'backup.restore';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) select v_org,v_staff_role,key from public.permission_catalog where key in ('organization.view','masters.view','transaction.view','transaction.create','transaction.edit','transaction.print','stock.view');
  insert into public.organization_members(organization_id,user_id,role_id,status) values(v_org,v_uid,v_owner_role,'active');
  insert into public.organization_settings(organization_id,currency,updated_by) values(v_org,upper(trim(p_currency)),v_uid);
  insert into public.accounts(organization_id,code,name,account_type,system_key) values
    (v_org,'1000','Cash','asset','cash'),(v_org,'1010','Bank','asset','bank'),(v_org,'1100','Accounts Receivable','asset','accounts_receivable'),
    (v_org,'1200','Inventory','asset','inventory'),(v_org,'1300','Input Tax','asset','input_tax'),(v_org,'2000','Accounts Payable','liability','accounts_payable'),
    (v_org,'2100','Output Tax','liability','output_tax'),(v_org,'3000','Owner Equity','equity','equity'),(v_org,'4000','Sales Revenue','income','sales_revenue'),
    (v_org,'4100','Service Revenue','income','service_revenue'),(v_org,'4200','Other Income','income','other_income'),(v_org,'5000','Cost of Goods Sold','cogs','cogs'),(v_org,'6000','Operating Expense','expense','operating_expense');
  select id into v_cash from public.accounts where organization_id=v_org and system_key='cash';
  select id into v_bank from public.accounts where organization_id=v_org and system_key='bank';
  insert into public.payment_methods(organization_id,name,account_id) values(v_org,'Cash',v_cash),(v_org,'Bank',v_bank);
  insert into public.warehouses(organization_id,code,name) values(v_org,'MAIN','Main Warehouse');
  insert into public.document_sequences(organization_id,sequence_key,prefix) values
    (v_org,'invoice','INV'),(v_org,'quotation','QT'),(v_org,'purchase','PI'),(v_org,'receipt','RV'),(v_org,'payment','PV'),(v_org,'expense','EV'),(v_org,'credit_note','CN'),(v_org,'debit_note','DN'),(v_org,'journal','JV'),(v_org,'stock_adjustment','SA');
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
    values(v_org,v_uid,'organization.created','organization',v_org::text,jsonb_build_object('name',trim(p_name)));
  return v_org;
end $$;
revoke all on function public.create_organization(text,text) from public, anon;
grant execute on function public.create_organization(text,text) to authenticated;

create or replace function public.post_transaction(p_transaction_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_uid uuid := auth.uid();
  v_tx public.transactions%rowtype;
  v_settings public.organization_settings%rowtype;
  v_existing jsonb;
  v_doc_no text;
  v_journal uuid;
  v_line public.transaction_lines%rowtype;
  v_product public.products%rowtype;
  v_tax public.tax_codes%rowtype;
  v_wh uuid;
  v_policy text;
  v_stock public.stock_balances%rowtype;
  v_next_qty numeric(18,4);
  v_new_avg numeric(18,6);
  v_unit_cost numeric(18,6);
  v_cogs numeric(18,2) := 0;
  v_sales_revenue numeric(18,2) := 0;
  v_service_revenue numeric(18,2) := 0;
  v_inventory_purchase numeric(18,2) := 0;
  v_expense_purchase numeric(18,2) := 0;
  v_input_tax numeric(18,2) := 0;
  v_nonrecoverable_tax numeric(18,2) := 0;
  v_output_tax numeric(18,2) := 0;
  v_debit numeric(18,2);
  v_credit numeric(18,2);
  v_payment_account uuid;
  v_ar uuid; v_ap uuid; v_inventory uuid; v_input_tax_acct uuid; v_output_tax_acct uuid; v_sales uuid; v_service uuid; v_cogs_acct uuid; v_expense uuid; v_equity uuid; v_other_income uuid;
  v_line_base numeric(18,2); v_line_net numeric(18,2); v_line_tax numeric(18,2); v_line_total numeric(18,2);
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then raise exception 'idempotency key must contain at least 8 characters'; end if;

  select * into v_tx from public.transactions where id=p_transaction_id for update;
  if not found then raise exception 'transaction not found'; end if;
  if not private.has_permission(v_tx.organization_id,v_uid,'transaction.post') then raise exception 'posting permission denied'; end if;

  select result into v_existing from public.posting_requests where organization_id=v_tx.organization_id and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;

  if v_tx.status='posted' then return jsonb_build_object('transaction_id',v_tx.id,'document_no',v_tx.document_no,'status','posted','idempotent',true); end if;
  if v_tx.status not in ('draft','approved') then raise exception 'transaction status % cannot be posted',v_tx.status; end if;
  if v_tx.needs_review then raise exception 'transaction requires review before posting'; end if;
  perform private.assert_period_open(v_tx.organization_id,v_tx.transaction_date);
  select * into v_settings from public.organization_settings where organization_id=v_tx.organization_id;

  if not exists(select 1 from public.transaction_lines where transaction_id=v_tx.id and organization_id=v_tx.organization_id) and v_tx.transaction_type not in ('journal','transfer') then
    raise exception 'transaction requires at least one line';
  end if;

  for v_line in select * from public.transaction_lines where transaction_id=v_tx.id and organization_id=v_tx.organization_id order by line_no for update
  loop
    if v_settings.tax_enabled and v_line.tax_code_id is not null then
      select * into v_tax from public.tax_codes where id=v_line.tax_code_id and organization_id=v_tx.organization_id and status='active' and effective_from<=v_tx.transaction_date and (effective_to is null or effective_to>=v_tx.transaction_date);
      if not found then raise exception 'tax code is not effective for transaction date'; end if;
      v_line.tax_rate := v_tax.rate; v_line.tax_classification:=v_tax.classification; v_line.tax_inclusive:=v_tax.inclusive;
      if v_line.input_tax_recoverable is null then v_line.input_tax_recoverable:=v_tax.input_recoverable_default; end if;
    else
      v_line.tax_rate:=0; v_line.tax_classification:='out_of_scope'; v_line.tax_inclusive:=false; v_line.input_tax_recoverable:=false;
    end if;
    v_line_base := round((v_line.quantity*v_line.unit_price - v_line.discount_amount)::numeric,2);
    if v_line_base < 0 then raise exception 'line discount exceeds line value'; end if;
    if v_line.tax_inclusive and v_line.tax_rate>0 then
      v_line_total:=v_line_base;
      v_line_net:=round(v_line_base/(1+(v_line.tax_rate/100)),2);
      v_line_tax:=round(v_line_total-v_line_net,2);
    else
      v_line_net:=v_line_base;
      v_line_tax:=round(v_line_net*(v_line.tax_rate/100),2);
      v_line_total:=round(v_line_net+v_line_tax,2);
    end if;
    update public.transaction_lines set tax_rate=v_line.tax_rate,tax_classification=v_line.tax_classification,tax_inclusive=v_line.tax_inclusive,input_tax_recoverable=v_line.input_tax_recoverable,line_net=v_line_net,line_tax=v_line_tax,line_total=v_line_total where id=v_line.id;
  end loop;

  select coalesce(sum(line_net),0),coalesce(sum(discount_amount),0),coalesce(sum(line_tax),0),coalesce(sum(line_total),0)
    into v_tx.subtotal,v_tx.discount_total,v_tx.tax_total,v_tx.grand_total
  from public.transaction_lines where transaction_id=v_tx.id and organization_id=v_tx.organization_id;
  v_tx.balance_total:=greatest(round(v_tx.grand_total-v_tx.paid_total,2),0);
  if v_tx.document_no is null then v_doc_no:=private.allocate_document_no(v_tx.organization_id,v_tx.transaction_type); else v_doc_no:=v_tx.document_no; end if;

  v_ar:=private.system_account_id(v_tx.organization_id,'accounts_receivable'); v_ap:=private.system_account_id(v_tx.organization_id,'accounts_payable');
  v_inventory:=private.system_account_id(v_tx.organization_id,'inventory'); v_input_tax_acct:=private.system_account_id(v_tx.organization_id,'input_tax');
  v_output_tax_acct:=private.system_account_id(v_tx.organization_id,'output_tax'); v_sales:=private.system_account_id(v_tx.organization_id,'sales_revenue');
  v_service:=private.system_account_id(v_tx.organization_id,'service_revenue'); v_cogs_acct:=private.system_account_id(v_tx.organization_id,'cogs');
  v_expense:=private.system_account_id(v_tx.organization_id,'operating_expense'); v_equity:=private.system_account_id(v_tx.organization_id,'equity'); v_other_income:=private.system_account_id(v_tx.organization_id,'other_income');
  if v_tx.payment_method_id is not null then select account_id into v_payment_account from public.payment_methods where id=v_tx.payment_method_id and organization_id=v_tx.organization_id and status='active'; end if;

  if v_tx.transaction_type in ('sale','service_sale','mixed_sale','purchase') then
    for v_line in select * from public.transaction_lines where transaction_id=v_tx.id and organization_id=v_tx.organization_id order by line_no
    loop
      if v_line.product_id is not null then select * into v_product from public.products where id=v_line.product_id and organization_id=v_tx.organization_id; else continue; end if;
      if v_product.item_type='inventory' then
        v_wh:=coalesce(v_line.warehouse_id,v_tx.warehouse_id);
        if v_wh is null then raise exception 'warehouse required for inventory line %',v_line.line_no; end if;
        insert into public.stock_balances(organization_id,product_id,warehouse_id,quantity,average_cost) values(v_tx.organization_id,v_product.id,v_wh,0,v_product.average_cost) on conflict do nothing;
        select * into v_stock from public.stock_balances where organization_id=v_tx.organization_id and product_id=v_product.id and warehouse_id=v_wh for update;
        if v_tx.transaction_type='purchase' then
          v_unit_cost:=round(((v_line.line_net + case when coalesce(v_line.input_tax_recoverable,false) then 0 else v_line.line_tax end)/v_line.quantity)::numeric,6);
          v_next_qty:=v_stock.quantity+v_line.quantity;
          if v_next_qty=0 then v_new_avg:=v_stock.average_cost; else v_new_avg:=round(((v_stock.quantity*v_stock.average_cost)+(v_line.quantity*v_unit_cost))/v_next_qty,6); end if;
          update public.stock_balances set quantity=v_next_qty,average_cost=v_new_avg,updated_at=now() where organization_id=v_tx.organization_id and product_id=v_product.id and warehouse_id=v_wh;
          update public.products set average_cost=v_new_avg,updated_at=now() where id=v_product.id;
          update public.transaction_lines set unit_cost_snapshot=v_unit_cost where id=v_line.id;
          insert into public.stock_movements(organization_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_in,unit_cost,reason,created_by) values(v_tx.organization_id,v_tx.id,v_line.id,v_product.id,v_wh,v_line.quantity,v_unit_cost,'purchase',v_uid);
          v_inventory_purchase:=v_inventory_purchase+v_line.line_net+case when coalesce(v_line.input_tax_recoverable,false) then 0 else v_line.line_tax end;
        else
          v_policy:=coalesce(v_product.negative_stock_policy,v_settings.negative_stock_policy);
          v_next_qty:=v_stock.quantity-v_line.quantity;
          if v_next_qty<0 and v_policy='block' then raise exception 'negative stock blocked for %',v_product.name; end if;
          if v_next_qty<0 and v_policy='warn' then
            if not v_tx.negative_stock_confirmed then raise exception 'negative stock requires confirmation for %',v_product.name; end if;
            if not private.has_permission(v_tx.organization_id,v_uid,'stock.negative_override') then raise exception 'negative stock override permission denied'; end if;
          end if;
          v_unit_cost:=v_stock.average_cost;
          update public.stock_balances set quantity=v_next_qty,updated_at=now() where organization_id=v_tx.organization_id and product_id=v_product.id and warehouse_id=v_wh;
          update public.transaction_lines set unit_cost_snapshot=v_unit_cost where id=v_line.id;
          insert into public.stock_movements(organization_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_out,unit_cost,reason,created_by) values(v_tx.organization_id,v_tx.id,v_line.id,v_product.id,v_wh,v_line.quantity,v_unit_cost,'sale',v_uid);
          v_cogs:=v_cogs+round(v_line.quantity*v_unit_cost,2);
        end if;
      end if;
      if v_tx.transaction_type in ('sale','service_sale','mixed_sale') then
        if v_product.item_type in ('service','labour','outside_work') then v_service_revenue:=v_service_revenue+v_line.line_net; else v_sales_revenue:=v_sales_revenue+v_line.line_net; end if;
        v_output_tax:=v_output_tax+v_line.line_tax;
      elsif v_tx.transaction_type='purchase' and v_product.item_type<>'inventory' then
        v_expense_purchase:=v_expense_purchase+v_line.line_net+case when coalesce(v_line.input_tax_recoverable,false) then 0 else v_line.line_tax end;
      end if;
      if v_tx.transaction_type='purchase' and coalesce(v_line.input_tax_recoverable,false) then v_input_tax:=v_input_tax+v_line.line_tax; end if;
    end loop;
  elsif v_tx.transaction_type='expense' then
    select coalesce(sum(line_net + case when coalesce(input_tax_recoverable,false) then 0 else line_tax end),0),coalesce(sum(case when coalesce(input_tax_recoverable,false) then line_tax else 0 end),0) into v_expense_purchase,v_input_tax from public.transaction_lines where transaction_id=v_tx.id;
  elsif v_tx.transaction_type in ('receipt','payment','income','capital','drawing') and v_payment_account is null then
    raise exception 'payment method with linked cash/bank account is required';
  elsif v_tx.transaction_type not in ('quotation','receipt','payment','income','capital','drawing') then
    raise exception 'posting for transaction type % is not enabled yet',v_tx.transaction_type;
  end if;

  if v_tx.transaction_type <> 'quotation' then
    insert into public.journals(organization_id,transaction_id,journal_date,status,created_by) values(v_tx.organization_id,v_tx.id,v_tx.transaction_date,'posted',v_uid) returning id into v_journal;
    if v_tx.transaction_type in ('sale','service_sale','mixed_sale') then
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_ar,v_tx.party_id,v_doc_no,v_tx.grand_total);
      if v_sales_revenue>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_sales,v_tx.party_id,v_doc_no,v_sales_revenue); end if;
      if v_service_revenue>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_service,v_tx.party_id,v_doc_no,v_service_revenue); end if;
      if v_output_tax>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_output_tax_acct,v_tx.party_id,v_doc_no,v_output_tax); end if;
      if v_cogs>0 then
        insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(v_tx.organization_id,v_journal,v_cogs_acct,v_doc_no,v_cogs);
        insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(v_tx.organization_id,v_journal,v_inventory,v_doc_no,v_cogs);
      end if;
      if v_tx.party_id is null then raise exception 'customer required for credit sale'; end if;
      insert into public.open_items(organization_id,transaction_id,party_id,item_type,original_amount,due_date) values(v_tx.organization_id,v_tx.id,v_tx.party_id,'receivable',v_tx.grand_total,v_tx.due_date);
    elsif v_tx.transaction_type='purchase' then
      if v_tx.party_id is null then raise exception 'supplier required for purchase'; end if;
      if v_inventory_purchase>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_inventory,v_tx.party_id,v_doc_no,v_inventory_purchase); end if;
      if v_expense_purchase>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_expense,v_tx.party_id,v_doc_no,v_expense_purchase); end if;
      if v_input_tax>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_input_tax_acct,v_tx.party_id,v_doc_no,v_input_tax); end if;
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_ap,v_tx.party_id,v_doc_no,v_tx.grand_total);
      insert into public.open_items(organization_id,transaction_id,party_id,item_type,original_amount,due_date) values(v_tx.organization_id,v_tx.id,v_tx.party_id,'payable',v_tx.grand_total,v_tx.due_date);
    elsif v_tx.transaction_type='expense' then
      if v_payment_account is null then raise exception 'payment method required for expense'; end if;
      if v_expense_purchase>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_expense,v_tx.party_id,v_doc_no,v_expense_purchase); end if;
      if v_input_tax>0 then insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_input_tax_acct,v_tx.party_id,v_doc_no,v_input_tax); end if;
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_payment_account,v_tx.party_id,v_doc_no,v_tx.grand_total);
    elsif v_tx.transaction_type='receipt' then
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_payment_account,v_tx.party_id,v_doc_no,v_tx.grand_total);
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_ar,v_tx.party_id,v_doc_no,v_tx.grand_total);
    elsif v_tx.transaction_type='payment' then
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit) values(v_tx.organization_id,v_journal,v_ap,v_tx.party_id,v_doc_no,v_tx.grand_total);
      insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,credit) values(v_tx.organization_id,v_journal,v_payment_account,v_tx.party_id,v_doc_no,v_tx.grand_total);
    elsif v_tx.transaction_type='income' then
      insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(v_tx.organization_id,v_journal,v_payment_account,v_doc_no,v_tx.grand_total);
      insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(v_tx.organization_id,v_journal,v_other_income,v_doc_no,v_tx.grand_total);
    elsif v_tx.transaction_type='capital' then
      insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(v_tx.organization_id,v_journal,v_payment_account,v_doc_no,v_tx.grand_total);
      insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(v_tx.organization_id,v_journal,v_equity,v_doc_no,v_tx.grand_total);
    elsif v_tx.transaction_type='drawing' then
      insert into public.journal_lines(organization_id,journal_id,account_id,description,debit) values(v_tx.organization_id,v_journal,v_equity,v_doc_no,v_tx.grand_total);
      insert into public.journal_lines(organization_id,journal_id,account_id,description,credit) values(v_tx.organization_id,v_journal,v_payment_account,v_doc_no,v_tx.grand_total);
    end if;
    select round(coalesce(sum(debit),0),2),round(coalesce(sum(credit),0),2) into v_debit,v_credit from public.journal_lines where journal_id=v_journal;
    if v_debit<>v_credit then raise exception 'journal is unbalanced: debit %, credit %',v_debit,v_credit; end if;
  end if;

  perform set_config('app.allow_posted_mutation','on',true);
  update public.transactions set document_no=v_doc_no,sequence_key=private.sequence_key_for(v_tx.transaction_type),subtotal=v_tx.subtotal,discount_total=v_tx.discount_total,tax_total=v_tx.tax_total,grand_total=v_tx.grand_total,balance_total=v_tx.balance_total,status='posted',posted_at=now(),posted_by=v_uid where id=v_tx.id;
  perform set_config('app.allow_posted_mutation','off',true);
  v_existing:=jsonb_build_object('transaction_id',v_tx.id,'document_no',v_doc_no,'status','posted','grand_total',v_tx.grand_total);
  insert into public.posting_requests(organization_id,idempotency_key,transaction_id,result,created_by) values(v_tx.organization_id,p_idempotency_key,v_tx.id,v_existing,v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(v_tx.organization_id,v_uid,'transaction.posted','transaction',v_tx.id::text,v_existing);
  return v_existing;
end $$;
revoke all on function public.post_transaction(uuid,text) from public, anon;
grant execute on function public.post_transaction(uuid,text) to authenticated;

create or replace function public.allocate_open_item(p_payment_transaction_id uuid,p_open_item_id uuid,p_amount numeric)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_pay public.transactions%rowtype; v_open public.open_items%rowtype; v_id uuid; v_new numeric;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_amount<=0 then raise exception 'allocation amount must be positive'; end if;
  select * into v_pay from public.transactions where id=p_payment_transaction_id and status='posted' for update;
  if not found or v_pay.transaction_type not in ('receipt','payment') then raise exception 'posted receipt/payment required'; end if;
  if not private.has_permission(v_pay.organization_id,v_uid,'transaction.post') then raise exception 'allocation permission denied'; end if;
  select * into v_open from public.open_items where id=p_open_item_id and organization_id=v_pay.organization_id for update;
  if not found or v_open.status='void' then raise exception 'open item not available'; end if;
  if (v_pay.transaction_type='receipt' and v_open.item_type<>'receivable') or (v_pay.transaction_type='payment' and v_open.item_type<>'payable') then raise exception 'allocation type mismatch'; end if;
  v_new:=v_open.allocated_amount+p_amount;
  if v_new>v_open.original_amount then raise exception 'allocation exceeds open balance'; end if;
  insert into public.allocations(organization_id,payment_transaction_id,open_item_id,amount,created_by) values(v_pay.organization_id,v_pay.id,v_open.id,p_amount,v_uid) returning id into v_id;
  update public.open_items set allocated_amount=v_new,status=case when v_new=v_open.original_amount then 'settled' else 'partially_paid' end where id=v_open.id;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(v_pay.organization_id,v_uid,'allocation.created','allocation',v_id::text,jsonb_build_object('open_item_id',v_open.id,'amount',p_amount));
  return v_id;
end $$;
revoke all on function public.allocate_open_item(uuid,uuid,numeric) from public, anon;
grant execute on function public.allocate_open_item(uuid,uuid,numeric) to authenticated;

create or replace function public.void_transaction(p_transaction_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_tx public.transactions%rowtype; v_j public.journals%rowtype; v_rev uuid; v_m public.stock_movements%rowtype; v_a public.allocations%rowtype; v_open public.open_items%rowtype; v_result jsonb;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters'; end if;
  select * into v_tx from public.transactions where id=p_transaction_id for update;
  if not found then raise exception 'transaction not found'; end if;
  if not private.has_permission(v_tx.organization_id,v_uid,'transaction.void') then raise exception 'void permission denied'; end if;
  if v_tx.status='void' then return jsonb_build_object('transaction_id',v_tx.id,'document_no',v_tx.document_no,'status','void','idempotent',true); end if;
  if v_tx.status<>'posted' then raise exception 'only posted transactions can be voided'; end if;
  perform private.assert_period_open(v_tx.organization_id,v_tx.transaction_date);
  select * into v_open from public.open_items where transaction_id=v_tx.id and organization_id=v_tx.organization_id;
  if found and v_open.allocated_amount>0 then raise exception 'cannot void an invoice/bill with allocations; reverse allocations first'; end if;
  for v_a in select * from public.allocations where payment_transaction_id=v_tx.id and organization_id=v_tx.organization_id for update loop
    update public.open_items set allocated_amount=greatest(allocated_amount-v_a.amount,0),status=case when greatest(allocated_amount-v_a.amount,0)=0 then 'open' else 'partially_paid' end where id=v_a.open_item_id;
  end loop;
  delete from public.allocations where payment_transaction_id=v_tx.id and organization_id=v_tx.organization_id;
  if found then update public.open_items set status='void' where transaction_id=v_tx.id and organization_id=v_tx.organization_id; end if;
  for v_m in select * from public.stock_movements where transaction_id=v_tx.id and organization_id=v_tx.organization_id order by created_at for update loop
    update public.stock_balances set quantity=quantity-v_m.quantity_in+v_m.quantity_out,updated_at=now() where organization_id=v_tx.organization_id and product_id=v_m.product_id and warehouse_id=v_m.warehouse_id;
    insert into public.stock_movements(organization_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_in,quantity_out,unit_cost,reason,created_by)
      values(v_tx.organization_id,v_tx.id,v_m.transaction_line_id,v_m.product_id,v_m.warehouse_id,v_m.quantity_out,v_m.quantity_in,v_m.unit_cost,'void reversal',v_uid);
  end loop;
  select * into v_j from public.journals where transaction_id=v_tx.id and reversal_of is null;
  if found then
    insert into public.journals(organization_id,transaction_id,journal_date,status,reversal_of,created_by) values(v_tx.organization_id,v_tx.id,current_date,'posted',v_j.id,v_uid) returning id into v_rev;
    insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit,credit)
      select organization_id,v_rev,account_id,party_id,'Reversal of '||coalesce(v_tx.document_no,''),credit,debit from public.journal_lines where journal_id=v_j.id;
    update public.journals set status='reversed' where id=v_j.id;
  end if;
  perform set_config('app.allow_posted_mutation','on',true);
  update public.transactions set status='void',voided_at=now(),voided_by=v_uid where id=v_tx.id;
  perform set_config('app.allow_posted_mutation','off',true);
  v_result:=jsonb_build_object('transaction_id',v_tx.id,'document_no',v_tx.document_no,'status','void');
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(v_tx.organization_id,v_uid,'transaction.voided','transaction',v_tx.id::text,v_result);
  return v_result;
end $$;
revoke all on function public.void_transaction(uuid,text) from public, anon;
grant execute on function public.void_transaction(uuid,text) to authenticated;
;
