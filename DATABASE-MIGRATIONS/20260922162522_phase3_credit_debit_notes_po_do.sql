-- 20260922162522  phase3_credit_debit_notes_po_do
-- Applied to Supabase project pwzpljitxamthgqllgtu


create or replace function private.save_and_post_extra(p_org uuid, p_tx jsonb, p_lines jsonb, p_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
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
    paid_total=0,balance_total=case when v_financial then s_tot else 0 end,status='posted',posted_at=now(),posted_by=v_uid,updated_at=now() where id=v_id;

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

  v_prev:=jsonb_build_object('transaction_id',v_id,'document_no',v_no,'status','posted','grand_total',s_tot,'applied_to_original',v_apply);
  insert into public.posting_requests(organization_id,company_id,idempotency_key,transaction_id,result,created_by) values(p_org,v_company,p_key,v_id,v_prev,v_uid);
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'transaction.posted','transaction',v_id::text,v_prev||jsonb_build_object('transaction_type',v_type,'against',v_against));

  if not exists (select 1 from public.transactions where id=v_id and status='posted' and document_no=v_no) then raise exception 'post verification failed'; end if;
  return v_prev||jsonb_build_object('verified',true,
    'journal_count',(select count(*) from public.journals where transaction_id=v_id),
    'stock_movement_count',(select count(*) from public.stock_movements where transaction_id=v_id),
    'ar_ap_count',(select count(*) from public.open_items where transaction_id=v_id));
end $$;

/* One entry point for the editor. Everything runs in one database transaction:
   any error rolls back the whole save & post. */
create or replace function private.save_and_post_any(p_org uuid, p_tx jsonb, p_lines jsonb, p_media uuid[], p_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
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
end $$;

create or replace function public.save_and_post_any(p_org uuid, p_tx jsonb, p_lines jsonb, p_media uuid[], p_key text) returns jsonb
language sql set search_path='' as $$ select private.save_and_post_any($1,$2,$3,$4,$5) $$;
revoke all on function public.save_and_post_any(uuid,jsonb,jsonb,uuid[],text) from public, anon;
grant execute on function public.save_and_post_any(uuid,jsonb,jsonb,uuid[],text) to authenticated;
;
