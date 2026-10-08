-- 20260923080000  phase3_engine_live_state
-- Applied to Supabase project pwzpljitxamthgqllgtu

CREATE OR REPLACE FUNCTION private.in_verified_restore()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if coalesce(current_setting('app.restore_in_progress', true),'') <> '1' then return false; end if;
  return to_regclass('pg_temp._rmap') is not null;
end $function$
;

CREATE OR REPLACE FUNCTION private.audit_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if private.in_verified_restore() then return null; end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(coalesce(new.organization_id,old.organization_id),auth.uid(),tg_argv[0]||'.'||lower(tg_op),tg_argv[0],
    coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id',to_jsonb(new)->>'product_id'),
    case when tg_op<>'INSERT' then to_jsonb(old) end, case when tg_op<>'DELETE' then to_jsonb(new) end);
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION private.guard_posted_transaction_media()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_status text;
begin
  if private.in_verified_restore() then return coalesce(new,old); end if;
  select status into v_status from public.transactions where id=coalesce(new.transaction_id,old.transaction_id);
  if v_status in ('posted','void') then raise exception 'photos on a posted invoice cannot be changed'; end if;
  return coalesce(new,old);
end $function$
;

CREATE OR REPLACE FUNCTION private.capture_transaction_document_snapshots()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org jsonb;
  v_party jsonb := '{}'::jsonb;
  v_profile jsonb := '{}'::jsonb;
begin
  if new.status = 'posted' and old.status is distinct from 'posted' then
    select jsonb_build_object(
      'legal_name', s.legal_name,
      'operating_name', s.operating_name,
      'email', s.email,
      'phone', s.phone,
      'address', s.address,
      'website', s.website,
      'tax_registered', s.tax_registered,
      'tax_registration_no', s.tax_registration_no,
      'currency', s.currency,
      'tax_enabled', s.tax_enabled,
      'default_tax_rate', s.default_tax_rate,
      'prices_include_tax', s.prices_include_tax,
      'logo_storage_path', s.logo_storage_path, 'settings', s.settings, 'country', s.country
    ) into v_org
    from public.organization_settings s
    where s.organization_id = new.organization_id;

    if new.party_id is not null then
      select to_jsonb(p) - 'notes' - 'credit_limit' - 'created_by' into v_party
      from public.parties p
      where p.id = new.party_id and p.organization_id = new.organization_id;
    end if;

    if new.document_profile_version_id is null then
      select dp.active_version_id, dp.id into new.document_profile_version_id, new.document_profile_id
      from public.document_profiles dp
      where dp.organization_id = new.organization_id and dp.is_active and dp.active_version_id is not null
        and dp.profile_type = case new.transaction_type when 'sale' then 'invoice' when 'mixed_sale' then 'invoice' when 'service_sale' then 'service_invoice'
          when 'quotation' then 'quotation' when 'purchase' then 'purchase_invoice' when 'purchase_order' then 'purchase_order' when 'receipt' then 'receipt_voucher'
          when 'payment' then 'payment_voucher' when 'expense' then 'expense_voucher' when 'credit_note' then 'credit_note' when 'debit_note' then 'debit_note'
          when 'delivery_note' then 'delivery_note' else 'voucher' end
      order by dp.created_at desc limit 1;
    end if;
    if new.document_profile_version_id is not null then
      select jsonb_build_object(
        'profile_id', dp.id,
        'profile_name', dp.name,
        'profile_type', dp.profile_type,
        'version_id', dpv.id,
        'version', dpv.version,
        'page_size', dp.page_size,
        'orientation', dp.orientation,
        'custom_width_mm', dp.custom_width_mm,
        'custom_height_mm', dp.custom_height_mm,
        'configuration', dpv.configuration
      ) into v_profile
      from public.document_profile_versions dpv
      join public.document_profiles dp on dp.id = dpv.document_profile_id and dp.organization_id = dpv.organization_id
      where dpv.id = new.document_profile_version_id and dpv.organization_id = new.organization_id;
    end if;

    new.organization_snapshot := coalesce(v_org, '{}'::jsonb);
    new.party_snapshot := coalesce(v_party, '{}'::jsonb);
    new.document_profile_snapshot := coalesce(v_profile, '{}'::jsonb);
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.post_transaction(p_transaction_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      if v_line.product_id is not null then
        select * into v_product from public.products where id=v_line.product_id and organization_id=v_tx.organization_id;
      else
        -- free-text line (typed labour, one-off charge): no stock, but revenue/expense must still post
        select * into v_product from public.products where false;
        v_product.item_type := case when v_tx.transaction_type = 'sale' then 'non_inventory' else 'service' end;
      end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION private.save_and_post_extra(p_org uuid, p_tx jsonb, p_lines jsonb, p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid:=auth.uid(); v_type text:=p_tx->>'transaction_type'; v_prev jsonb; v_set public.organization_settings;
  v_company uuid; v_branch uuid; v_party uuid:=nullif(p_tx->>'party_id','')::uuid; v_wh uuid:=nullif(p_tx->>'warehouse_id','')::uuid;
  v_against uuid:=nullif(p_tx->>'against_transaction_id','')::uuid; v_date date:=coalesce(nullif(p_tx->>'transaction_date','')::date,current_date);
  v_id uuid; v_no text; l jsonb; n int:=0; v_prod public.products; v_tax public.tax_codes; v_rate numeric; v_class text; v_incl boolean; v_rec boolean;
  v_qty numeric; v_price numeric; v_disc numeric; v_base numeric; v_net numeric; v_vat numeric; v_tot numeric; v_line uuid; v_lwh uuid;
  s_net numeric:=0; s_vat numeric:=0; s_tot numeric:=0; s_disc numeric:=0; v_journal uuid; v_stock public.stock_balances; v_cost numeric;
  v_ar uuid; v_ap uuid; v_inv_acc uuid; v_cogs uuid; v_sales uuid; v_svc uuid; v_out uuid; v_in uuid; v_exp uuid;
  v_open public.open_items; v_apply numeric; v_party_type text; v_financial boolean; d numeric; c numeric; v_nonrec numeric:=0;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if v_type not in ('credit_note','debit_note','purchase_order','delivery_note') then raise exception 'unsupported type %',v_type; end if;
  if p_key is null or length(p_key)<8 then raise exception 'idempotency key must contain at least 8 characters'; end if;
  select result into v_prev from public.posting_requests where organization_id=p_org and idempotency_key=p_key;
  if v_prev is not null then return v_prev||jsonb_build_object('verified',true,'idempotent',true); end if;
  if not private.has_permission(p_org,v_uid,'transaction.create') or not private.has_permission(p_org,v_uid,'transaction.post') then raise exception 'posting permission denied'; end if;
  perform private.assert_period_open(p_org,v_date);
  select * into v_set from public.organization_settings where organization_id=p_org;
  v_company:=coalesce(nullif(p_tx->>'company_id','')::uuid,private.default_company_id(p_org));
  v_branch:=coalesce(nullif(p_tx->>'branch_id','')::uuid,private.default_branch_id(p_org,v_company));
  v_financial:=v_type in ('credit_note','debit_note');
  if v_party is null then raise exception '% requires a %',replace(v_type,'_',' '),case when v_type in ('credit_note','delivery_note') then 'customer' else 'supplier' end; end if;
  select party_type into v_party_type from public.parties where id=v_party and organization_id=p_org and status='active';
  if v_party_type is null then raise exception 'party not found in this company'; end if;
  if v_type in ('credit_note','delivery_note') and v_party_type not in ('customer','both') then raise exception 'choose a customer'; end if;
  if v_type in ('debit_note','purchase_order') and v_party_type not in ('supplier','both') then raise exception 'choose a supplier'; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'at least one line is required'; end if;
  if v_against is not null and not exists (select 1 from public.transactions where id=v_against and organization_id=p_org and status='posted' and party_id=v_party
     and transaction_type = any(case when v_type='credit_note' then array['sale','service_sale','mixed_sale'] else array['purchase'] end)) then
    raise exception 'the original document must be a posted % for the same party', case when v_type='credit_note' then 'invoice' else 'purchase invoice' end; end if;

  insert into public.transactions(organization_id,company_id,branch_id,transaction_type,transaction_date,due_date,party_id,warehouse_id,status,currency,notes,
     vehicle_id,service_job_id,created_by)
  values(p_org,v_company,v_branch,v_type,v_date,nullif(p_tx->>'due_date','')::date,v_party,v_wh,'draft',coalesce(v_set.currency,'AED'),
     nullif(trim(p_tx->>'notes'),''),nullif(p_tx->>'vehicle_id','')::uuid,nullif(p_tx->>'service_job_id','')::uuid,v_uid) returning id into v_id;

  if v_financial then
    v_ar:=private.system_account_id(p_org,'accounts_receivable'); v_ap:=private.system_account_id(p_org,'accounts_payable');
    v_inv_acc:=private.system_account_id(p_org,'inventory'); v_cogs:=private.system_account_id(p_org,'cogs');
    v_sales:=private.system_account_id(p_org,'sales_revenue'); v_svc:=private.system_account_id(p_org,'service_revenue');
    v_out:=private.system_account_id(p_org,'output_tax'); v_in:=private.system_account_id(p_org,'input_tax'); v_exp:=private.system_account_id(p_org,'operating_expense');
    insert into public.journals(organization_id,company_id,transaction_id,journal_date,status,created_by) values(p_org,v_company,v_id,v_date,'posted',v_uid) returning id into v_journal;
  end if;

  for l in select value from jsonb_array_elements(p_lines) loop
    n:=n+1;
    v_qty:=coalesce(nullif(l->>'quantity','')::numeric,0); v_price:=coalesce(nullif(l->>'unit_price','')::numeric,0); v_disc:=coalesce(nullif(l->>'discount_amount','')::numeric,0);
    if trim(coalesce(l->>'description',''))='' then raise exception 'line % description required',n; end if;
    if v_qty<=0 then raise exception 'line % quantity must be greater than zero',n; end if;
    if v_price<0 or v_disc<0 then raise exception 'line % values cannot be negative',n; end if;
    v_base:=round(v_qty*v_price-v_disc,2); if v_base<0 then raise exception 'line % discount exceeds line value',n; end if;
    v_prod:=null; if nullif(l->>'product_id','') is not null then select * into v_prod from public.products where id=(l->>'product_id')::uuid and organization_id=p_org; end if;
    v_rate:=0; v_class:='out_of_scope'; v_incl:=false; v_rec:=false; v_tax:=null;
    if coalesce(v_set.tax_enabled,false) and nullif(l->>'tax_code_id','') is not null then
      select * into v_tax from public.tax_codes where id=(l->>'tax_code_id')::uuid and organization_id=p_org and status='active' and effective_from<=v_date and (effective_to is null or effective_to>=v_date);
      if not found then raise exception 'line % tax code is not effective for the date',n; end if;
      v_rate:=v_tax.rate; v_class:=v_tax.classification; v_incl:=v_tax.inclusive; v_rec:=coalesce(nullif(l->>'input_tax_recoverable','')::boolean,v_tax.input_recoverable_default);
    end if;
    if v_incl and v_rate>0 then v_tot:=v_base; v_net:=round(v_base/(1+v_rate/100),2); v_vat:=v_tot-v_net;
    else v_net:=v_base; v_vat:=round(v_net*v_rate/100,2); v_tot:=v_net+v_vat; end if;
    v_lwh:=coalesce(nullif(l->>'warehouse_id','')::uuid,v_wh);
    insert into public.transaction_lines(organization_id,company_id,transaction_id,line_no,product_id,warehouse_id,description,quantity,unit_price,discount_amount,
      tax_code_id,tax_rate,tax_classification,tax_inclusive,input_tax_recoverable,line_net,line_tax,line_total)
    values(p_org,v_company,v_id,n,v_prod.id,v_lwh,trim(l->>'description'),v_qty,v_price,v_disc,v_tax.id,v_rate,v_class,v_incl,v_rec,v_net,v_vat,v_tot) returning id into v_line;
    s_net:=s_net+v_net; s_vat:=s_vat+v_vat; s_tot:=s_tot+v_tot; s_disc:=s_disc+v_disc;

    if v_financial then
      if v_type='credit_note' then
        insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit)
        values(p_org,v_company,v_journal,case when v_prod.item_type in ('inventory','non_inventory') then v_sales else coalesce(v_svc,v_sales) end,v_party,trim(l->>'description'),v_net,0);
        if v_vat<>0 then insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_out,v_party,'Output VAT reversal',v_vat,0); end if;
      else
        if v_prod.item_type='inventory' then
          insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_inv_acc,v_party,trim(l->>'description'),0,v_net);
        else
          insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_exp,v_party,trim(l->>'description'),0,v_net);
        end if;
        if v_vat<>0 then
          if v_rec then insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_in,v_party,'Input VAT reversal',0,v_vat);
          else insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_exp,v_party,'Non-recoverable VAT reversal',0,v_vat); end if;
        end if;
      end if;
      -- stock: goods returned by customer come back in; goods returned to supplier go out
      if v_prod.item_type='inventory' then
        if v_lwh is null then raise exception 'warehouse required for stock line %',n; end if;
        insert into public.stock_balances(organization_id,company_id,product_id,warehouse_id,quantity,average_cost) values(p_org,v_company,v_prod.id,v_lwh,0,v_prod.average_cost) on conflict do nothing;
        select * into v_stock from public.stock_balances where organization_id=p_org and product_id=v_prod.id and warehouse_id=v_lwh for update;
        v_cost:=coalesce(nullif(v_stock.average_cost,0),v_prod.average_cost,0);
        if v_type='credit_note' then
          update public.stock_balances set quantity=quantity+v_qty,updated_at=now() where organization_id=p_org and product_id=v_prod.id and warehouse_id=v_lwh;
          insert into public.stock_movements(organization_id,company_id,branch_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_in,quantity_out,unit_cost,reason,created_by)
          values(p_org,v_company,v_branch,v_id,v_line,v_prod.id,v_lwh,v_qty,0,v_cost,'customer_return',v_uid);
          insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_inv_acc,null,'Stock returned: '||v_prod.name,round(v_qty*v_cost,2),0);
          insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_cogs,null,'Cost reversal: '||v_prod.name,0,round(v_qty*v_cost,2));
        else
          if v_stock.quantity-v_qty<0 and coalesce(v_prod.negative_stock_policy,v_set.negative_stock_policy,'block')='block' then raise exception 'negative stock blocked for %',v_prod.name; end if;
          update public.stock_balances set quantity=quantity-v_qty,updated_at=now() where organization_id=p_org and product_id=v_prod.id and warehouse_id=v_lwh;
          insert into public.stock_movements(organization_id,company_id,branch_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_in,quantity_out,unit_cost,reason,created_by)
          values(p_org,v_company,v_branch,v_id,v_line,v_prod.id,v_lwh,0,v_qty,case when v_qty>0 then round(v_net/v_qty,6) else v_cost end,'supplier_return',v_uid);
        end if;
      end if;
    end if;
  end loop;

  s_net:=round(s_net,2); s_vat:=round(s_vat,2); s_tot:=round(s_tot,2);
  if v_financial then
    if v_type='credit_note' then
      insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_ar,v_party,'Credit note to customer',0,s_tot);
    else
      insert into public.journal_lines(organization_id,company_id,journal_id,account_id,party_id,description,debit,credit) values(p_org,v_company,v_journal,v_ap,v_party,'Debit note to supplier',s_tot,0);
    end if;
    select sum(debit),sum(credit) into d,c from public.journal_lines where journal_id=v_journal;
    if d<>c then raise exception 'journal is unbalanced: debit %, credit %',d,c; end if;
  end if;

  v_no:=private.allocate_document_no(p_org,v_type);
  update public.transactions set document_no=v_no,sequence_key=private.sequence_key_for(v_type),subtotal=s_net,discount_total=round(s_disc,2),tax_total=s_vat,grand_total=s_tot,
    paid_total=0,balance_total=case when v_financial then s_tot else 0 end,updated_at=now() where id=v_id;

  if v_financial then
    -- offset against the original invoice/bill first; anything left stays open for refund or future use
    v_apply:=0;
    if v_against is not null then
      select * into v_open from public.open_items where transaction_id=v_against and organization_id=p_org for update;
      if found and v_open.status in ('open','partially_paid') then
        v_apply:=least(s_tot,v_open.original_amount-v_open.allocated_amount);
        if v_apply>0 then
          update public.open_items set allocated_amount=allocated_amount+v_apply,
            status=case when allocated_amount+v_apply>=original_amount then 'settled' else 'partially_paid' end where id=v_open.id;
          insert into public.allocations(organization_id,company_id,payment_transaction_id,open_item_id,amount,created_by) values(p_org,v_company,v_id,v_open.id,v_apply,v_uid);
        end if;
      end if;
    end if;
    insert into public.open_items(organization_id,company_id,transaction_id,party_id,item_type,original_amount,allocated_amount,due_date,status)
    values(p_org,v_company,v_id,v_party,case when v_type='credit_note' then 'payable' else 'receivable' end,s_tot,v_apply,v_date,
      case when v_apply>=s_tot then 'settled' when v_apply>0 then 'partially_paid' else 'open' end);
    update public.transactions set paid_total=v_apply,balance_total=s_tot-v_apply where id=v_id;
  end if;
  update public.transactions set status='posted',posted_at=now(),posted_by=v_uid,updated_at=now() where id=v_id;

  v_prev:=jsonb_build_object('transaction_id',v_id,'document_no',v_no,'status','posted','grand_total',s_tot,'applied_to_original',v_apply);
  insert into public.posting_requests(organization_id,company_id,idempotency_key,transaction_id,result,created_by) values(p_org,v_company,p_key,v_id,v_prev,v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'transaction.posted','transaction',v_id::text,v_prev||jsonb_build_object('transaction_type',v_type,'against',v_against));

  if not exists (select 1 from public.transactions where id=v_id and status='posted' and document_no=v_no) then raise exception 'post verification failed'; end if;
  return v_prev||jsonb_build_object('verified',true,
    'journal_count',(select count(*) from public.journals where transaction_id=v_id),
    'stock_movement_count',(select count(*) from public.stock_movements where transaction_id=v_id),
    'ar_ap_count',(select count(*) from public.open_items where transaction_id=v_id));
end $function$
;

CREATE OR REPLACE FUNCTION private.save_and_post_any(p_org uuid, p_tx jsonb, p_lines jsonb, p_media uuid[], p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_type text:=p_tx->>'transaction_type'; r jsonb; v_job uuid:=nullif(p_tx->>'service_job_id','')::uuid; v_id uuid;
begin
  if v_type in ('credit_note','debit_note','purchase_order','delivery_note') then r:=private.save_and_post_extra(p_org,p_tx,p_lines,p_key);
  elsif coalesce(array_length(p_media,1),0)>0 then r:=private.save_and_post_transaction_with_media(p_org,p_tx,p_lines,p_media,p_key);
  else r:=private.save_and_post_transaction(p_org,p_tx,p_lines,p_key); end if;
  v_id:=(r->>'transaction_id')::uuid;
  -- a posted service invoice closes its job card
  if v_job is not null and v_type in ('sale','service_sale','mixed_sale') and coalesce((r->>'idempotent')::boolean,false)=false then
    update public.service_jobs set status='invoiced', invoice_transaction_id=v_id, updated_at=now() where id=v_job and organization_id=p_org and status not in ('delivered','cancelled');
  end if;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION private.restore_rows(p_backup jsonb, p_key text, p_table text, p_org uuid, p_defer text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb; v_row jsonb; v_txt text; m text; v_new uuid; c text; v_cols text[]; v_user text;
begin
  v_rows:=p_backup->p_key;
  if v_rows is null then return; end if;
  if jsonb_typeof(v_rows)='object' then v_rows:=jsonb_build_array(v_rows); end if;
  select array_agg(column_name::text) into v_cols from information_schema.columns where table_schema='public' and table_name=p_table;
  for v_row in select x from jsonb_array_elements(v_rows) x loop
    v_txt:=v_row::text;
    for m in select distinct (regexp_matches(v_txt,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}','g'))[1] loop
      select new into v_new from _rmap where old=m::uuid;
      if v_new is not null then v_txt:=replace(v_txt,m,v_new::text); end if;
    end loop;
    v_row:=v_txt::jsonb;
    -- keep only real columns, blank deferred links, drop user ids that do not exist in this project
    v_row:=(select coalesce(jsonb_object_agg(k,v),'{}') from jsonb_each(v_row) e(k,v) where k = any(v_cols) and not (k = any(coalesce(p_defer,'{}'))));
    foreach c in array array['created_by','updated_by','actor_id','user_id','posted_by','approved_by','voided_by','deleted_by','changed_by','recorded_by','requested_by','restored_by'] loop
      if v_row ? c and v_row->>c is not null then
        select id::text into v_user from auth.users where id=(v_row->>c)::uuid;
        if v_user is null then v_row:=jsonb_set(v_row,array[c],'null'::jsonb); end if;
      end if;
    end loop;
    if 'organization_id' = any(v_cols) then v_row:=jsonb_set(v_row,'{organization_id}',to_jsonb(p_org)); end if;
    execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I,$1)',p_table,p_table) using v_row;
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION private.restore_business_backup(p_backup jsonb, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid:=auth.uid(); v_old_org uuid; v_new_org uuid:=gen_random_uuid(); v_name text; r jsonb; t text; v_row jsonb; v_txt text; m text; v_new uuid;
  v_owner uuid; v_report jsonb:='{}'; v_cnt bigint; v_exp bigint; v_d numeric; v_c numeric; v_a numeric; v_l numeric; v_e numeric; v_pl numeric;
  v_tables text[]; v_user_cols text[]:=array['created_by','updated_by','actor_id','user_id','posted_by','approved_by','voided_by','deleted_by','changed_by','recorded_by','requested_by','restored_by','assigned_to'];
  v_key text; v_val text; v_bak numeric; v_live numeric;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  -- ============ 1. VALIDATE ============
  if p_backup is null or p_backup->>'format' is distinct from 'business-platform-backup' then raise exception 'This file is not a Business Platform backup.'; end if;
  if p_backup->>'schema_version' is null then raise exception 'The backup has no schema version.'; end if;
  if p_backup->'organization' is null or jsonb_typeof(p_backup->'organization')<>'object' then raise exception 'The backup has no organization record.'; end if;
  v_old_org:=(p_backup->'organization'->>'id')::uuid;
  if v_old_org is null then raise exception 'The backup organization id is missing.'; end if;
  foreach t in array array['transactions','transaction_lines','journals','journal_lines','accounts','parties','products'] loop
    if p_backup ? t and jsonb_typeof(p_backup->t)<>'array' then raise exception 'Backup section % is damaged.',t; end if;
  end loop;
  -- every journal in the backup must balance before anything is written
  select coalesce(sum((x->>'debit')::numeric),0), coalesce(sum((x->>'credit')::numeric),0) into v_d,v_c from jsonb_array_elements(coalesce(p_backup->'journal_lines','[]')) x;
  if round(v_d,2)<>round(v_c,2) then raise exception 'The backup itself is not balanced (debit %, credit %). Restore refused.',v_d,v_c; end if;
  v_name:=coalesce(nullif(trim(p_name),''), (p_backup->'organization'->>'name')||' (restored '||to_char(now(),'YYYY-MM-DD')||')');

  -- ============ 2. ID MAP ============
  create temporary table if not exists _rmap(old uuid primary key, new uuid) on commit drop;
  delete from _rmap where true;
  insert into _rmap(old,new) values(v_old_org,v_new_org);
  v_tables:=array['companies','branches','roles','organization_roles','members','parties','party_roles','party_contacts','party_addresses','party_notes','vehicles','vehicle_mileage_history',
    'product_categories','products','product_prices','warehouses','accounts','account_groups','payment_methods','tax_codes','accounting_periods','document_sequences','transactions','transaction_lines',
    'transaction_media','document_snapshots','journals','journal_lines','stock_movements','open_items','allocations','service_jobs','service_job_tasks','service_job_items','service_job_status_history',
    'document_profiles','document_profile_versions','attachments','voice_recordings','audit_log'];
  foreach t in array v_tables loop
    insert into _rmap(old,new) select (x->>'id')::uuid, gen_random_uuid() from jsonb_array_elements(coalesce(p_backup->t,'[]')) x
    where x ? 'id' and (x->>'id') ~* '^[0-9a-f-]{36}$' on conflict do nothing;
  end loop;

  -- ============ 3. RESTORE ============
  insert into public.organizations(id,name,status,created_by,created_at) values(v_new_org,v_name,'active',v_uid,now());
  perform set_config('app.restore_in_progress','1',true);
  -- a new organization is seeded with defaults; clear them so the backup is restored exactly
  delete from public.organization_members where organization_id=v_new_org;
  delete from public.organization_role_permissions where organization_id=v_new_org;
  delete from public.organization_roles where organization_id=v_new_org;
  delete from public.payment_methods where organization_id=v_new_org;
  delete from public.warehouses where organization_id=v_new_org;
  delete from public.branches where organization_id=v_new_org;
  delete from public.accounts where organization_id=v_new_org;
  delete from public.account_groups where organization_id=v_new_org;
  delete from public.tax_codes where organization_id=v_new_org;
  delete from public.document_sequences where organization_id=v_new_org;
  delete from public.document_profiles where organization_id=v_new_org;
  delete from public.accounting_periods where organization_id=v_new_org;
  delete from public.companies where organization_id=v_new_org;
  delete from public.organization_settings where organization_id=v_new_org;
  delete from public.audit_log where organization_id=v_new_org;
  perform private.restore_rows(p_backup,'settings','organization_settings',v_new_org,'{}');
  update public.organization_settings set organization_id=v_new_org where organization_id=v_new_org;
  perform private.restore_rows(p_backup,'companies','companies',v_new_org,'{}');
  perform private.restore_rows(p_backup,'branches','branches',v_new_org,'{}');
  perform private.restore_rows(p_backup,'roles','organization_roles',v_new_org,'{}');
  perform private.restore_rows(p_backup,'role_permissions','organization_role_permissions',v_new_org,'{}');
  perform private.restore_rows(p_backup,'members','organization_members',v_new_org,'{}');
  -- whoever restores must be able to open the restored copy
  select id into v_owner from public.organization_roles where organization_id=v_new_org and lower(name)='owner' limit 1;
  if v_owner is null then insert into public.organization_roles(organization_id,name,is_system) values(v_new_org,'Owner',true) returning id into v_owner; end if;
  insert into public.organization_members(organization_id,user_id,role_id,status)
  values(v_new_org,v_uid,v_owner,'active') on conflict (organization_id,user_id) do update set role_id=excluded.role_id,status='active';
  perform private.restore_rows(p_backup,'account_groups','account_groups',v_new_org,'{}');
  perform private.restore_rows(p_backup,'accounts','accounts',v_new_org,'{parent_id}');
  perform private.restore_rows(p_backup,'warehouses','warehouses',v_new_org,'{}');
  perform private.restore_rows(p_backup,'tax_codes','tax_codes',v_new_org,'{}');
  perform private.restore_rows(p_backup,'payment_methods','payment_methods',v_new_org,'{}');
  perform private.restore_rows(p_backup,'accounting_periods','accounting_periods',v_new_org,'{}');
  perform private.restore_rows(p_backup,'document_sequences','document_sequences',v_new_org,'{}');
  perform private.restore_rows(p_backup,'product_categories','product_categories',v_new_org,'{parent_id}');
  perform private.restore_rows(p_backup,'products','products',v_new_org,'{photo_attachment_id}');
  perform private.restore_rows(p_backup,'product_prices','product_prices',v_new_org,'{}');
  perform private.restore_rows(p_backup,'parties','parties',v_new_org,'{}');
  delete from public.party_roles where organization_id=v_new_org;
  perform private.restore_rows(p_backup,'party_roles','party_roles',v_new_org,'{}');
  perform private.restore_rows(p_backup,'party_contacts','party_contacts',v_new_org,'{}');
  perform private.restore_rows(p_backup,'party_addresses','party_addresses',v_new_org,'{}');
  perform private.restore_rows(p_backup,'party_notes','party_notes',v_new_org,'{}');
  perform private.restore_rows(p_backup,'vehicles','vehicles',v_new_org,'{}');
  delete from public.vehicle_mileage_history where organization_id=v_new_org;  -- drop rows created by triggers
  perform private.restore_rows(p_backup,'vehicle_mileage_history','vehicle_mileage_history',v_new_org,'{service_job_id}');
  perform private.restore_rows(p_backup,'document_profiles','document_profiles',v_new_org,'{active_version_id,reference_attachment_id}');
  perform private.restore_rows(p_backup,'document_profile_versions','document_profile_versions',v_new_org,'{}');
  perform private.restore_rows(p_backup,'service_jobs','service_jobs',v_new_org,'{invoice_transaction_id}');
  delete from public.service_job_status_history where organization_id=v_new_org;
  perform private.restore_rows(p_backup,'transactions','transactions',v_new_org,'{}');
  perform private.restore_rows(p_backup,'transaction_lines','transaction_lines',v_new_org,'{}');
  perform private.restore_rows(p_backup,'journals','journals',v_new_org,'{}');
  perform private.restore_rows(p_backup,'journal_lines','journal_lines',v_new_org,'{}');
  perform private.restore_rows(p_backup,'stock_movements','stock_movements',v_new_org,'{}');
  perform private.restore_rows(p_backup,'stock_balances','stock_balances',v_new_org,'{}');
  perform private.restore_rows(p_backup,'open_items','open_items',v_new_org,'{}');
  perform private.restore_rows(p_backup,'allocations','allocations',v_new_org,'{}');
  perform private.restore_rows(p_backup,'service_job_tasks','service_job_tasks',v_new_org,'{}');
  perform private.restore_rows(p_backup,'service_job_items','service_job_items',v_new_org,'{}');
  perform private.restore_rows(p_backup,'service_job_status_history','service_job_status_history',v_new_org,'{}');
  perform private.restore_rows(p_backup,'attachments','attachments',v_new_org,'{}');
  perform private.restore_rows(p_backup,'transaction_media','transaction_media',v_new_org,'{}');
  perform private.restore_rows(p_backup,'voice_recordings','voice_recordings',v_new_org,'{}');
  delete from public.document_snapshots where organization_id=v_new_org;
  perform private.restore_rows(p_backup,'document_snapshots','document_snapshots',v_new_org,'{}');

  -- circular links, second pass
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'accounts','[]')) x loop
    if v_row->>'parent_id' is not null then update public.accounts set parent_id=(select new from _rmap where old=(v_row->>'parent_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end if; end loop;
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'product_categories','[]')) x loop
    if v_row->>'parent_id' is not null then update public.product_categories set parent_id=(select new from _rmap where old=(v_row->>'parent_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end if; end loop;
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'products','[]')) x loop
    if v_row->>'photo_attachment_id' is not null then update public.products set photo_attachment_id=(select new from _rmap where old=(v_row->>'photo_attachment_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end if; end loop;
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'document_profiles','[]')) x loop
    update public.document_profiles set active_version_id=(select new from _rmap where old=(v_row->>'active_version_id')::uuid),
      reference_attachment_id=(select new from _rmap where old=(v_row->>'reference_attachment_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end loop;
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'service_jobs','[]')) x loop
    update public.service_jobs set invoice_transaction_id=(select new from _rmap where old=(v_row->>'invoice_transaction_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end loop;
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'vehicle_mileage_history','[]')) x loop
    if v_row->>'service_job_id' is not null then update public.vehicle_mileage_history set service_job_id=(select new from _rmap where old=(v_row->>'service_job_id')::uuid) where id=(select new from _rmap where old=(v_row->>'id')::uuid); end if; end loop;

  -- ============ 4. READ BACK / VERIFY COUNTS & RELATIONSHIPS ============
  foreach t in array array['companies','branches','parties','vehicles','products','warehouses','accounts','tax_codes','transactions','transaction_lines','journals','journal_lines',
    'stock_movements','open_items','allocations','service_jobs','service_job_tasks','service_job_items','attachments','document_profiles','document_profile_versions','document_sequences'] loop
    v_exp:=jsonb_array_length(coalesce(p_backup->t,'[]'));
    execute format('select count(*) from public.%I where organization_id=$1',t) into v_cnt using v_new_org;
    if v_cnt<>v_exp then raise exception 'Restore check failed: % has % rows but the backup has %.',t,v_cnt,v_exp; end if;
    v_report:=v_report||jsonb_build_object(t,v_cnt);
  end loop;
  if exists (select 1 from public.transaction_lines l where l.organization_id=v_new_org and not exists(select 1 from public.transactions x where x.id=l.transaction_id)) then raise exception 'Restore check failed: orphan transaction lines.'; end if;
  if exists (select 1 from public.journal_lines l where l.organization_id=v_new_org and not exists(select 1 from public.journals j where j.id=l.journal_id)) then raise exception 'Restore check failed: orphan journal lines.'; end if;
  if exists (select 1 from public.transactions x where x.organization_id=v_new_org and x.party_id is not null and not exists(select 1 from public.parties p where p.id=x.party_id)) then raise exception 'Restore check failed: documents point to missing customers.'; end if;

  -- ============ 5. TRIAL BALANCE ============
  select coalesce(sum(debit),0),coalesce(sum(credit),0) into v_d,v_c from public.journal_lines where organization_id=v_new_org;
  if round(v_d,2)<>round(v_c,2) then raise exception 'Restore check failed: trial balance does not balance (% vs %).',v_d,v_c; end if;
  if round(v_d,2)<>round((select coalesce(sum((x->>'debit')::numeric),0) from jsonb_array_elements(coalesce(p_backup->'journal_lines','[]')) x),2) then raise exception 'Restore check failed: trial balance does not match the backup.'; end if;
  v_report:=v_report||jsonb_build_object('trial_balance_debit',round(v_d,2),'trial_balance_credit',round(v_c,2));

  -- ============ 6. BALANCE SHEET ============
  select coalesce(sum(case when a.account_type='asset' then jl.debit-jl.credit else 0 end),0),
         coalesce(sum(case when a.account_type='liability' then jl.credit-jl.debit else 0 end),0),
         coalesce(sum(case when a.account_type='equity' then jl.credit-jl.debit else 0 end),0),
         coalesce(sum(case when a.account_type in ('income') then jl.credit-jl.debit when a.account_type in ('cogs','expense') then jl.debit-jl.credit*0-(jl.debit-jl.credit)*0 else 0 end),0)
    into v_a,v_l,v_e,v_pl
  from public.journal_lines jl join public.accounts a on a.id=jl.account_id where jl.organization_id=v_new_org;
  select coalesce(sum(case when a.account_type='income' then jl.credit-jl.debit when a.account_type in ('cogs','expense') then -(jl.debit-jl.credit) else 0 end),0) into v_pl
  from public.journal_lines jl join public.accounts a on a.id=jl.account_id where jl.organization_id=v_new_org;
  if round(v_a,2)<>round(v_l+v_e+v_pl,2) then raise exception 'Restore check failed: balance sheet does not balance (assets % vs liabilities+equity+profit %).',round(v_a,2),round(v_l+v_e+v_pl,2); end if;
  v_report:=v_report||jsonb_build_object('assets',round(v_a,2),'liabilities',round(v_l,2),'equity_plus_profit',round(v_e+v_pl,2));

  -- ============ 7. STOCK ============
  select coalesce(sum(quantity),0) into v_live from public.stock_balances where organization_id=v_new_org;
  select coalesce(sum((x->>'quantity')::numeric),0) into v_bak from jsonb_array_elements(coalesce(p_backup->'stock_balances','[]')) x;
  if round(v_live,4)<>round(v_bak,4) then raise exception 'Restore check failed: stock quantity % does not match the backup %.',v_live,v_bak; end if;
  if exists (select 1 from public.stock_balances b where b.organization_id=v_new_org and not exists (select 1 from public.products p where p.id=b.product_id)) then raise exception 'Restore check failed: stock points to missing products.'; end if;
  v_report:=v_report||jsonb_build_object('stock_quantity',round(v_live,4));

  -- ============ 8. AR / AP ============
  for v_key in select unnest(array['receivable','payable']) loop
    select coalesce(sum(original_amount-allocated_amount),0) into v_live from public.open_items where organization_id=v_new_org and item_type=v_key and status in ('open','partially_paid');
    select coalesce(sum((x->>'original_amount')::numeric-(x->>'allocated_amount')::numeric),0) into v_bak from jsonb_array_elements(coalesce(p_backup->'open_items','[]')) x where x->>'item_type'=v_key and x->>'status' in ('open','partially_paid');
    if round(v_live,2)<>round(v_bak,2) then raise exception 'Restore check failed: % outstanding % does not match the backup %.',v_key,v_live,v_bak; end if;
    v_report:=v_report||jsonb_build_object(v_key,round(v_live,2));
  end loop;
  if exists (select 1 from public.allocations a where a.organization_id=v_new_org and not exists(select 1 from public.open_items o where o.id=a.open_item_id)) then raise exception 'Restore check failed: allocations point to missing invoices.'; end if;

  -- ============ 9. VAT ============
  select coalesce(sum(l.line_tax),0) into v_live from public.transaction_lines l join public.transactions x on x.id=l.transaction_id where l.organization_id=v_new_org and x.status='posted';
  select coalesce(sum((l->>'line_tax')::numeric),0) into v_bak from jsonb_array_elements(coalesce(p_backup->'transaction_lines','[]')) l
    where (select x->>'status' from jsonb_array_elements(coalesce(p_backup->'transactions','[]')) x where x->>'id'=l->>'transaction_id')='posted';
  if round(v_live,2)<>round(v_bak,2) then raise exception 'Restore check failed: VAT % does not match the backup %.',v_live,v_bak; end if;
  v_report:=v_report||jsonb_build_object('vat_posted',round(v_live,2));

  -- ============ 10. NUMBERING ============
  for v_row in select x from jsonb_array_elements(coalesce(p_backup->'document_sequences','[]')) x loop
    select next_number into v_cnt from public.document_sequences where organization_id=v_new_org and sequence_key=v_row->>'sequence_key';
    if v_cnt is null or v_cnt<>(v_row->>'next_number')::bigint then raise exception 'Restore check failed: numbering for % was not restored.',v_row->>'sequence_key'; end if;
  end loop;
  if exists (select 1 from public.transactions x where x.organization_id=v_new_org and x.status='posted' and x.document_no is null) then raise exception 'Restore check failed: posted documents without numbers.'; end if;
  v_report:=v_report||jsonb_build_object('sequences',jsonb_array_length(coalesce(p_backup->'document_sequences','[]')));

  -- ============ 11. AUDIT ============
  insert into public.backup_manifests(organization_id,backup_type,status,schema_version,manifest,requested_by,completed_at,restored_at)
  values(v_new_org,'manual','restored',coalesce(p_backup->>'schema_version','unknown'),
    jsonb_build_object('restored_from_organization',v_old_org,'source_backup_id',p_backup->>'backup_id','source_created_at',p_backup->>'created_at','verification',v_report,'binary_files_copied',false),v_uid,now(),now());
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(v_new_org,v_uid,'backup.restored','organization',v_new_org::text,jsonb_build_object('source_organization',v_old_org,'verification',v_report));
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  select v_old_org,v_uid,'backup.restored_to_new_company','organization',v_new_org::text,jsonb_build_object('restored_organization',v_new_org)
  where exists (select 1 from public.organizations where id=v_old_org);

  perform set_config('app.restore_in_progress','0',true);
  return jsonb_build_object('verified',true,'organization_id',v_new_org,'name',v_name,'verification',v_report);
end $function$
;
