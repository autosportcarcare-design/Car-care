-- 20260922162234  phase3_reports_search_audit_status
-- Applied to Supabase project pwzpljitxamthgqllgtu


-- ============ generic audit for configuration / master tables ============
create or replace function private.audit_row() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(coalesce(new.organization_id,old.organization_id),auth.uid(),tg_argv[0]||'.'||lower(tg_op),tg_argv[0],
    coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id',to_jsonb(new)->>'product_id'),
    case when tg_op<>'INSERT' then to_jsonb(old) end, case when tg_op<>'DELETE' then to_jsonb(new) end);
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['products','tax_codes','warehouses','branches','payment_methods','document_profiles','companies','accounts','attachments'] loop
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$s', t);
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$s for each row execute function private.audit_row(%2$L)', t, rtrim(t,'s'));
  end loop;
end $$;

create or replace function private.block_audit_update() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'audit history cannot be edited'; end $$;
drop trigger if exists trg_audit_immutable on public.audit_log;
create trigger trg_audit_immutable before update on public.audit_log for each row execute function private.block_audit_update();

-- ============ service job status ============
create or replace function private.set_service_job_status(p_org uuid, p_job uuid, p_status text, p_note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_old text; v public.service_jobs;
begin
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'permission denied: service'; end if;
  if p_status not in ('draft','open','inspection','waiting_customer','in_progress','waiting_parts','completed','invoiced','delivered','cancelled') then raise exception 'invalid job status'; end if;
  select status into v_old from public.service_jobs where id=p_job and organization_id=p_org for update;
  if v_old is null then raise exception 'job not found'; end if;
  if v_old in ('delivered','cancelled') and p_status<>v_old then raise exception 'a % job cannot be reopened', v_old; end if;
  update public.service_jobs set status=p_status, delivered_at=case when p_status='delivered' then now() else delivered_at end,
    updated_by=v_uid, updated_at=now() where id=p_job returning * into v;
  if not exists (select 1 from public.service_job_status_history where service_job_id=p_job and to_status=p_status and created_at>now()-interval '2 seconds') then
    insert into public.service_job_status_history(organization_id,company_id,service_job_id,from_status,to_status,note,changed_by)
    values(p_org,v.company_id,p_job,v_old,p_status,nullif(p_note,''),v_uid);
  end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(p_org,v_uid,'service_job.status','service_job',p_job::text,jsonb_build_object('status',v_old),jsonb_build_object('status',p_status,'note',p_note));
  return to_jsonb(v);
end $$;

create or replace function private.update_service_job(p_org uuid, p_job uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_old public.service_jobs; v public.service_jobs; d jsonb:=private.strip_blank(p_data);
begin
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'permission denied: service'; end if;
  select * into v_old from public.service_jobs where id=p_job and organization_id=p_org for update;
  if not found then raise exception 'job not found'; end if;
  if v_old.status in ('delivered','cancelled') then raise exception 'a % job cannot be edited', v_old.status; end if;
  update public.service_jobs set complaint=d->>'complaint', inspection_notes=d->>'inspection_notes', requested_work=d->>'requested_work',
    completed_work=d->>'completed_work', notes=d->>'notes', promised_date=(d->>'promised_date')::date,
    mileage=coalesce((d->>'mileage')::numeric,mileage), updated_by=v_uid, updated_at=now() where id=p_job returning * into v;
  if (d->>'mileage') is not null and v.vehicle_id is not null and (d->>'mileage')::numeric is distinct from v_old.mileage then
    insert into public.vehicle_mileage_history(organization_id,vehicle_id,mileage,source,service_job_id,recorded_by)
    values(p_org,v.vehicle_id,(d->>'mileage')::numeric,'service_job',p_job,v_uid);
  end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(p_org,v_uid,'service_job.updated','service_job',p_job::text,to_jsonb(v_old),to_jsonb(v));
  return to_jsonb(v);
end $$;

create or replace function private.delete_service_task(p_org uuid, p_task uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v public.service_job_tasks;
begin
  if not private.has_permission(p_org,v_uid,'service.manage') then raise exception 'permission denied: service'; end if;
  delete from public.service_job_tasks where id=p_task and organization_id=p_org returning * into v;
  if not found then raise exception 'task not found'; end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values) values(p_org,v_uid,'service_job.task_deleted','service_job_task',p_task::text,to_jsonb(v));
  return true;
end $$;

-- ============ attachments: soft delete, never from a posted invoice ============
create or replace function private.delete_attachment(p_org uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if not private.is_org_member(p_org,v_uid) then raise exception 'permission denied'; end if;
  if exists (select 1 from public.transaction_media tm join public.transactions t on t.id=tm.transaction_id where tm.attachment_id=p_id and t.status in ('posted','void')) then
    raise exception 'this photo is part of a posted invoice and cannot be deleted'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce((select jsonb_agg(e) from public.transactions t, jsonb_array_elements(coalesce(t.media_snapshot,'[]')) e where t.organization_id=p_org),'[]')) x where x->>'attachment_id'=p_id::text) then
    raise exception 'this photo is part of a posted invoice and cannot be deleted'; end if;
  update public.attachments set deleted_at=now(), deleted_by=v_uid where id=p_id and organization_id=p_org and deleted_at is null;
  if not found then raise exception 'file not found'; end if;
  return true;
end $$;

-- ============ reports ============
create or replace function private.rpt_account_balances(p_org uuid, p_from date, p_to date)
returns table(account_id uuid, code text, name text, account_type text, system_key text, opening numeric, debit numeric, credit numeric, closing numeric)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.has_permission(p_org,auth.uid(),'accounting.view') then raise exception 'permission denied: accounting reports'; end if;
  return query
  select a.id,a.code,a.name,a.account_type,a.system_key,
    round(coalesce(sum(x.debit-x.credit) filter (where x.journal_date<p_from),0),2),
    round(coalesce(sum(x.debit) filter (where x.journal_date between p_from and p_to),0),2),
    round(coalesce(sum(x.credit) filter (where x.journal_date between p_from and p_to),0),2),
    round(coalesce(sum(x.debit-x.credit) filter (where x.journal_date<=p_to),0),2)
  from public.accounts a
  left join (select jl.account_id, jl.debit, jl.credit, j.journal_date from public.journal_lines jl join public.journals j on j.id=jl.journal_id
             where jl.organization_id=p_org and j.status in ('posted','reversed')) x on x.account_id=a.id
  where a.organization_id=p_org group by a.id,a.code,a.name,a.account_type,a.system_key order by a.code;
end $$;

create or replace function private.rpt_ledger(p_org uuid, p_account uuid, p_party uuid, p_from date, p_to date)
returns table(line_date date, document_no text, transaction_type text, transaction_id uuid, description text, debit numeric, credit numeric, balance numeric, is_opening boolean)
language plpgsql stable security definer set search_path='' as $$
declare v_open numeric;
begin
  if not private.has_permission(p_org,auth.uid(),'accounting.view') then raise exception 'permission denied: accounting reports'; end if;
  select coalesce(sum(jl.debit-jl.credit),0) into v_open from public.journal_lines jl join public.journals j on j.id=jl.journal_id
   where jl.organization_id=p_org and j.status in ('posted','reversed') and j.journal_date<p_from
     and (p_account is null or jl.account_id=p_account) and (p_party is null or jl.party_id=p_party);
  return query
  select p_from, null::text, null::text, null::uuid, 'Opening balance'::text, greatest(v_open,0), greatest(-v_open,0), round(v_open,2), true
  union all
  select * from (
    select j.journal_date, t.document_no, t.transaction_type, t.id, coalesce(jl.description,t.notes,''), jl.debit, jl.credit,
      round(v_open + sum(jl.debit-jl.credit) over (order by j.journal_date, t.document_no, jl.id),2), false
    from public.journal_lines jl join public.journals j on j.id=jl.journal_id left join public.transactions t on t.id=j.transaction_id
    where jl.organization_id=p_org and j.status in ('posted','reversed') and j.journal_date between p_from and p_to
      and (p_account is null or jl.account_id=p_account) and (p_party is null or jl.party_id=p_party)
    order by j.journal_date, t.document_no, jl.id) z;
end $$;

create or replace function private.rpt_vat(p_org uuid, p_from date, p_to date)
returns table(direction text, classification text, rate numeric, recoverable boolean, net numeric, tax numeric, documents bigint)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.has_permission(p_org,auth.uid(),'accounting.view') then raise exception 'permission denied: VAT report'; end if;
  return query
  select case when t.transaction_type in ('sale','service_sale','mixed_sale','income','credit_note','customer_refund') then 'output' else 'input' end,
    tl.tax_classification, tl.tax_rate, coalesce(tl.input_tax_recoverable,false),
    round(sum(tl.line_net * case when t.transaction_type in ('credit_note','debit_note') then -1 else 1 end),2),
    round(sum(tl.line_tax * case when t.transaction_type in ('credit_note','debit_note') then -1 else 1 end),2),
    count(distinct t.id)
  from public.transaction_lines tl join public.transactions t on t.id=tl.transaction_id
  where t.organization_id=p_org and t.status='posted' and t.transaction_date between p_from and p_to
    and t.transaction_type in ('sale','service_sale','mixed_sale','income','credit_note','purchase','expense','debit_note')
  group by 1,2,3,4 order by 1 desc,2,3;
end $$;

create or replace function private.rpt_open_items(p_org uuid, p_kind text, p_party uuid)
returns table(open_item_id uuid, party_id uuid, party_name text, transaction_id uuid, document_no text, doc_date date, due_date date, original numeric, allocated numeric, outstanding numeric, days_overdue int, status text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.has_permission(p_org,auth.uid(),'accounting.view') and not private.has_permission(p_org,auth.uid(),'transaction.view') then raise exception 'permission denied'; end if;
  return query
  select o.id,o.party_id,coalesce(p.display_name,p.name),o.transaction_id,t.document_no,t.transaction_date,o.due_date,o.original_amount,o.allocated_amount,
    round(o.original_amount-o.allocated_amount,2), greatest(current_date-coalesce(o.due_date,t.transaction_date),0), o.status
  from public.open_items o join public.transactions t on t.id=o.transaction_id left join public.parties p on p.id=o.party_id
  where o.organization_id=p_org and o.item_type=p_kind and o.status in ('open','partially_paid') and (p_party is null or o.party_id=p_party)
  order by coalesce(p.display_name,p.name), t.transaction_date;
end $$;

create or replace function private.rpt_invoice_profit(p_org uuid, p_from date, p_to date)
returns table(transaction_id uuid, document_no text, transaction_type text, doc_date date, party_name text, vehicle text, revenue numeric, stock_cost numeric, direct_cost numeric, profit numeric, margin numeric)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.has_permission(p_org,auth.uid(),'profit.view') then raise exception 'permission denied: profit'; end if;
  return query
  select t.id,t.document_no,t.transaction_type,t.transaction_date,coalesce(p.display_name,p.name),
    nullif(concat_ws(' ',v.plate_number,v.make,v.model),''),
    t.subtotal,
    round(coalesce((select sum(sm.quantity_out*sm.unit_cost) from public.stock_movements sm where sm.transaction_id=t.id),0),2),
    round(coalesce((select sum(tl.direct_cost_snapshot) from public.transaction_lines tl where tl.transaction_id=t.id),0),2),
    0::numeric, 0::numeric
  from public.transactions t left join public.parties p on p.id=t.party_id left join public.vehicles v on v.id=t.vehicle_id
  where t.organization_id=p_org and t.status='posted' and t.transaction_type in ('sale','service_sale','mixed_sale') and t.transaction_date between p_from and p_to
  order by t.transaction_date, t.document_no;
end $$;

create or replace function private.rpt_stock(p_org uuid)
returns table(product_id uuid, sku text, name text, item_type text, unit text, warehouse text, quantity numeric, average_cost numeric, value numeric, minimum_stock numeric, reorder_quantity numeric, sale_price numeric)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.has_permission(p_org,auth.uid(),'stock.view') then raise exception 'permission denied: stock'; end if;
  return query
  select pr.id,pr.sku,pr.name,pr.item_type,pr.unit,w.name,coalesce(b.quantity,0),coalesce(b.average_cost,pr.average_cost,0),
    round(coalesce(b.quantity,0)*coalesce(b.average_cost,0),2),pr.minimum_stock,pr.reorder_quantity,pr.sale_price
  from public.products pr left join public.stock_balances b on b.product_id=pr.id left join public.warehouses w on w.id=b.warehouse_id
  where pr.organization_id=p_org and pr.item_type='inventory' order by pr.name, w.name;
end $$;

create or replace function private.rpt_dashboard(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); r jsonb:='{}';
begin
  if not private.is_org_member(p_org,v_uid) then raise exception 'permission denied'; end if;
  if private.has_permission(p_org,v_uid,'transaction.view') then
    r:=r||jsonb_build_object(
      'sales_month',(select coalesce(sum(grand_total),0) from public.transactions where organization_id=p_org and status='posted' and transaction_type in ('sale','service_sale','mixed_sale') and date_trunc('month',transaction_date)=date_trunc('month',current_date)),
      'purchases_month',(select coalesce(sum(grand_total),0) from public.transactions where organization_id=p_org and status='posted' and transaction_type='purchase' and date_trunc('month',transaction_date)=date_trunc('month',current_date)),
      'receivable',(select coalesce(sum(original_amount-allocated_amount),0) from public.open_items where organization_id=p_org and item_type='receivable' and status in ('open','partially_paid')),
      'payable',(select coalesce(sum(original_amount-allocated_amount),0) from public.open_items where organization_id=p_org and item_type='payable' and status in ('open','partially_paid')),
      'drafts',(select count(*) from public.transactions where organization_id=p_org and status='draft'),
      'recent',(select coalesce(jsonb_agg(x),'[]') from (select id,document_no,transaction_type,transaction_date,grand_total,status from public.transactions where organization_id=p_org order by created_at desc limit 8) x));
  end if;
  if private.has_permission(p_org,v_uid,'accounting.view') then
    r:=r||jsonb_build_object('cash_bank',(select coalesce(sum(jl.debit-jl.credit),0) from public.journal_lines jl join public.journals j on j.id=jl.journal_id join public.accounts a on a.id=jl.account_id
       where jl.organization_id=p_org and j.status in ('posted','reversed') and a.system_key in ('cash','bank')));
  end if;
  r:=r||jsonb_build_object('open_jobs',(select count(*) from public.service_jobs where organization_id=p_org and status not in ('delivered','cancelled','invoiced')),
    'low_stock',(select count(*) from public.products pr where pr.organization_id=p_org and pr.item_type='inventory' and pr.status='active' and coalesce(pr.minimum_stock,0)>0
       and coalesce((select sum(quantity) from public.stock_balances b where b.product_id=pr.id),0) < pr.minimum_stock),
    'customers',(select count(*) from public.parties where organization_id=p_org and status='active' and party_type in ('customer','both')),
    'vehicles',(select count(*) from public.vehicles where organization_id=p_org and status='active'));
  return r;
end $$;

-- ============ global search ============
create or replace function private.global_search(p_org uuid, p_q text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); q text:=lower(trim(coalesce(p_q,''))); lk text; num numeric; r jsonb:='[]';
begin
  if not private.is_org_member(p_org,v_uid) then raise exception 'permission denied'; end if;
  if length(q)<2 then return r; end if;
  lk:='%'||replace(replace(q,'%',''),'_','')||'%';
  begin num:=replace(q,',','')::numeric; exception when others then num:=null; end;
  if private.has_permission(p_org,v_uid,'masters.view') then
    r:=r||coalesce((select jsonb_agg(jsonb_build_object('kind',case when party_type='supplier' then 'Supplier' else 'Customer' end,'id',id,'title',coalesce(display_name,name),
      'sub',concat_ws(' · ',party_code,mobile,tax_registration_no),'url','parties.html?id='||id)) from (select * from public.parties where organization_id=p_org and
      lower(concat_ws(' ',party_code,name,display_name,legal_name,mobile,alternate_mobile,whatsapp,telephone,email,alternate_email,tax_registration_no,spr_no,reference_no)) like lk limit 15) x),'[]');
    r:=r||coalesce((select jsonb_agg(jsonb_build_object('kind','Vehicle','id',id,'title',concat_ws(' ',plate_number,make,model),'sub',concat_ws(' · ',vehicle_code,chassis_vin),'url','vehicles.html?id='||id))
      from (select * from public.vehicles where organization_id=p_org and lower(concat_ws(' ',vehicle_code,plate_number,chassis_vin,engine_number,make,model)) like lk limit 15) x),'[]');
  end if;
  if private.has_permission(p_org,v_uid,'transaction.view') then
    r:=r||coalesce((select jsonb_agg(jsonb_build_object('kind','Document','id',id,'title',coalesce(document_no,'Draft')||' · '||replace(transaction_type,'_',' '),
      'sub',transaction_date||' · '||grand_total,'url','voucher-view.html?id='||id)) from (select * from public.transactions where organization_id=p_org and
      (lower(coalesce(document_no,'')) like lk or transaction_date::text like lk or (num is not null and (grand_total=num or subtotal=num))) order by transaction_date desc limit 20) x),'[]');
  end if;
  if private.has_permission(p_org,v_uid,'service.view') then
    r:=r||coalesce((select jsonb_agg(jsonb_build_object('kind','Job card','id',id,'title',coalesce(job_no,'Job')||' · '||coalesce(plate_no,''),'sub',concat_ws(' · ',status,vehicle_make,vehicle_model),'url','job-cards.html?id='||id))
      from (select * from public.service_jobs where organization_id=p_org and lower(concat_ws(' ',job_no,plate_no,chassis_no,customer_phone,complaint)) like lk limit 15) x),'[]');
  end if;
  if private.has_permission(p_org,v_uid,'stock.view') or private.has_permission(p_org,v_uid,'masters.view') then
    r:=r||coalesce((select jsonb_agg(jsonb_build_object('kind','Product','id',id,'title',name,'sub',concat_ws(' · ',sku,barcode,item_type),'url','stock.html?id='||id))
      from (select * from public.products where organization_id=p_org and lower(concat_ws(' ',sku,barcode,name,description)) like lk limit 15) x),'[]');
  end if;
  return r;
end $$;

-- ============ public wrappers + grants ============
create or replace function public.set_service_job_status(p_org uuid, p_job uuid, p_status text, p_note text) returns jsonb language sql set search_path='' as $$ select private.set_service_job_status($1,$2,$3,$4) $$;
create or replace function public.update_service_job(p_org uuid, p_job uuid, p_data jsonb) returns jsonb language sql set search_path='' as $$ select private.update_service_job($1,$2,$3) $$;
create or replace function public.delete_service_task(p_org uuid, p_task uuid) returns boolean language sql set search_path='' as $$ select private.delete_service_task($1,$2) $$;
create or replace function public.delete_attachment(p_org uuid, p_id uuid) returns boolean language sql set search_path='' as $$ select private.delete_attachment($1,$2) $$;
create or replace function public.rpt_account_balances(p_org uuid, p_from date, p_to date) returns table(account_id uuid, code text, name text, account_type text, system_key text, opening numeric, debit numeric, credit numeric, closing numeric) language sql stable set search_path='' as $$ select * from private.rpt_account_balances($1,$2,$3) $$;
create or replace function public.rpt_ledger(p_org uuid, p_account uuid, p_party uuid, p_from date, p_to date) returns table(line_date date, document_no text, transaction_type text, transaction_id uuid, description text, debit numeric, credit numeric, balance numeric, is_opening boolean) language sql stable set search_path='' as $$ select * from private.rpt_ledger($1,$2,$3,$4,$5) $$;
create or replace function public.rpt_vat(p_org uuid, p_from date, p_to date) returns table(direction text, classification text, rate numeric, recoverable boolean, net numeric, tax numeric, documents bigint) language sql stable set search_path='' as $$ select * from private.rpt_vat($1,$2,$3) $$;
create or replace function public.rpt_open_items(p_org uuid, p_kind text, p_party uuid) returns table(open_item_id uuid, party_id uuid, party_name text, transaction_id uuid, document_no text, doc_date date, due_date date, original numeric, allocated numeric, outstanding numeric, days_overdue int, status text) language sql stable set search_path='' as $$ select * from private.rpt_open_items($1,$2,$3) $$;
create or replace function public.rpt_invoice_profit(p_org uuid, p_from date, p_to date) returns table(transaction_id uuid, document_no text, transaction_type text, doc_date date, party_name text, vehicle text, revenue numeric, stock_cost numeric, direct_cost numeric, profit numeric, margin numeric) language sql stable set search_path='' as $$
  select transaction_id,document_no,transaction_type,doc_date,party_name,vehicle,revenue,stock_cost,direct_cost,round(revenue-stock_cost-direct_cost,2),case when revenue<>0 then round((revenue-stock_cost-direct_cost)/revenue*100,1) else 0 end from private.rpt_invoice_profit($1,$2,$3) $$;
create or replace function public.rpt_stock(p_org uuid) returns table(product_id uuid, sku text, name text, item_type text, unit text, warehouse text, quantity numeric, average_cost numeric, value numeric, minimum_stock numeric, reorder_quantity numeric, sale_price numeric) language sql stable set search_path='' as $$ select * from private.rpt_stock($1) $$;
create or replace function public.rpt_dashboard(p_org uuid) returns jsonb language sql stable set search_path='' as $$ select private.rpt_dashboard($1) $$;
create or replace function public.global_search(p_org uuid, p_q text) returns jsonb language sql stable set search_path='' as $$ select private.global_search($1,$2) $$;

do $$ declare f text; begin
  foreach f in array array['set_service_job_status(uuid,uuid,text,text)','update_service_job(uuid,uuid,jsonb)','delete_service_task(uuid,uuid)','delete_attachment(uuid,uuid)',
    'rpt_account_balances(uuid,date,date)','rpt_ledger(uuid,uuid,uuid,date,date)','rpt_vat(uuid,date,date)','rpt_open_items(uuid,text,uuid)','rpt_invoice_profit(uuid,date,date)',
    'rpt_stock(uuid)','rpt_dashboard(uuid)','global_search(uuid,text)'] loop
    execute 'revoke all on function public.'||f||' from public, anon';
    execute 'grant execute on function public.'||f||' to authenticated';
  end loop;
end $$;
;
