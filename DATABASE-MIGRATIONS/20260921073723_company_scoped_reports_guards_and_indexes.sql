-- 20260921073723  company_scoped_reports_guards_and_indexes
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.sync_party_roles() returns trigger language plpgsql security definer set search_path='' as $$
begin
  delete from public.party_roles where organization_id=new.organization_id and party_id=new.id;
  if new.party_type in ('customer','both') then insert into public.party_roles(organization_id,company_id,party_id,role) values(new.organization_id,new.company_id,new.id,'customer'); end if;
  if new.party_type in ('supplier','both') then insert into public.party_roles(organization_id,company_id,party_id,role) values(new.organization_id,new.company_id,new.id,'supplier'); end if;
  return new;
end $$;
revoke all on function private.sync_party_roles() from public,anon,authenticated;
drop trigger if exists parties_sync_roles on public.parties;
create trigger parties_sync_roles after insert or update of party_type,company_id on public.parties for each row execute function private.sync_party_roles();

create or replace function private.validate_transaction_links() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.company_id is null then raise exception 'company required'; end if;
  if new.party_id is not null and not exists(select 1 from public.parties p where p.id=new.party_id and p.organization_id=new.organization_id and p.company_id=new.company_id and p.status='active') then raise exception 'party does not belong to transaction company'; end if;
  if new.warehouse_id is not null and not exists(select 1 from public.warehouses w where w.id=new.warehouse_id and w.organization_id=new.organization_id and w.company_id=new.company_id and w.status='active') then raise exception 'warehouse does not belong to transaction company'; end if;
  if new.vehicle_id is not null and not exists(select 1 from public.vehicles v where v.id=new.vehicle_id and v.organization_id=new.organization_id and v.company_id=new.company_id and v.status='active' and (new.party_id is null or v.customer_id=new.party_id)) then raise exception 'vehicle does not belong to transaction company/customer'; end if;
  if new.service_job_id is not null and not exists(select 1 from public.service_jobs s where s.id=new.service_job_id and s.organization_id=new.organization_id and s.company_id=new.company_id and lower(s.status)<>'cancelled' and (new.party_id is null or s.customer_id=new.party_id) and (new.vehicle_id is null or s.vehicle_id=new.vehicle_id)) then raise exception 'service job does not belong to transaction company/customer/vehicle or is cancelled'; end if;
  return new;
end $$;
revoke all on function private.validate_transaction_links() from public,anon,authenticated;
drop trigger if exists zz_transactions_validate_links on public.transactions;
create trigger zz_transactions_validate_links before insert or update of company_id,party_id,warehouse_id,vehicle_id,service_job_id on public.transactions for each row execute function private.validate_transaction_links();

create or replace view public.report_trial_balance with (security_invoker=true) as
select a.organization_id,a.id account_id,a.code,a.name,a.account_type,
 round(coalesce(sum(jl.debit),0),2) debit,round(coalesce(sum(jl.credit),0),2) credit,round(coalesce(sum(jl.debit-jl.credit),0),2) balance,
 a.company_id
from public.accounts a
left join public.journal_lines jl on jl.organization_id=a.organization_id and jl.company_id=a.company_id and jl.account_id=a.id
left join public.journals j on j.id=jl.journal_id and j.organization_id=jl.organization_id and j.company_id=jl.company_id
group by a.organization_id,a.id,a.code,a.name,a.account_type,a.company_id;

create or replace view public.report_profit_loss with (security_invoker=true) as
select organization_id,account_id,code,name,account_type,
 case when account_type='income' then round(credit-debit,2) when account_type in ('cogs','expense') then round(debit-credit,2) else 0::numeric end amount,
 company_id
from public.report_trial_balance where account_type in ('income','cogs','expense');

create or replace view public.report_balance_sheet with (security_invoker=true) as
select tb.organization_id,tb.account_id,tb.code,tb.name,tb.account_type,
 case when tb.account_type='asset' then round(tb.debit-tb.credit,2) when tb.account_type in ('liability','equity') then round(tb.credit-tb.debit,2) else 0::numeric end amount,
 tb.company_id
from public.report_trial_balance tb where tb.account_type in ('asset','liability','equity')
union all
select pl.organization_id,null::uuid,'CURRENT_EARNINGS','Current Earnings','equity',
 round(sum(case when pl.account_type='income' then pl.amount when pl.account_type in ('cogs','expense') then -pl.amount else 0 end),2),pl.company_id
from public.report_profit_loss pl group by pl.organization_id,pl.company_id;

create or replace view public.report_day_book with (security_invoker=true) as
select t.organization_id,t.id transaction_id,t.document_no,t.transaction_type,t.transaction_date,t.party_id,p.name party_name,t.status,t.subtotal,t.tax_total,t.grand_total,t.balance_total,t.created_at,t.posted_at,t.company_id,t.branch_id
from public.transactions t left join public.parties p on p.id=t.party_id and p.organization_id=t.organization_id and p.company_id=t.company_id;

create or replace view public.report_stock_summary with (security_invoker=true) as
select sb.organization_id,sb.product_id,p.sku,p.name product_name,sb.warehouse_id,w.code warehouse_code,w.name warehouse_name,sb.quantity,sb.average_cost,round(sb.quantity*sb.average_cost,2) stock_value,sb.company_id
from public.stock_balances sb join public.products p on p.id=sb.product_id and p.organization_id=sb.organization_id and p.company_id=sb.company_id
join public.warehouses w on w.id=sb.warehouse_id and w.organization_id=sb.organization_id and w.company_id=sb.company_id;

create or replace view public.report_tax_summary with (security_invoker=true) as
select t.organization_id,
 round(coalesce(sum(case when t.transaction_type in ('sale','service_sale','mixed_sale') and t.status='posted' then l.line_tax else 0 end),0),2) output_tax,
 round(coalesce(sum(case when t.transaction_type in ('purchase','expense') and t.status='posted' and coalesce(l.input_tax_recoverable,false) then l.line_tax else 0 end),0),2) input_tax,
 round(coalesce(sum(case when t.transaction_type in ('sale','service_sale','mixed_sale') and t.status='posted' then l.line_tax else 0 end),0)-coalesce(sum(case when t.transaction_type in ('purchase','expense') and t.status='posted' and coalesce(l.input_tax_recoverable,false) then l.line_tax else 0 end),0),2) net_tax,
 t.company_id
from public.transactions t join public.transaction_lines l on l.transaction_id=t.id and l.organization_id=t.organization_id and l.company_id=t.company_id
group by t.organization_id,t.company_id;

create or replace view public.report_receivable_payable_ageing with (security_invoker=true) as
select oi.organization_id,oi.id open_item_id,oi.transaction_id,oi.party_id,p.name party_name,oi.item_type,oi.original_amount,oi.allocated_amount,round(oi.original_amount-oi.allocated_amount,2) outstanding,oi.due_date,oi.status,
 greatest(current_date-coalesce(oi.due_date,current_date),0) overdue_days,
 case when oi.status in ('settled','void') then 'Closed' when coalesce(oi.due_date,current_date)>=current_date then 'Current' when current_date-oi.due_date between 1 and 30 then '1-30' when current_date-oi.due_date between 31 and 60 then '31-60' when current_date-oi.due_date between 61 and 90 then '61-90' else '90+' end ageing_bucket,
 oi.company_id
from public.open_items oi join public.parties p on p.id=oi.party_id and p.organization_id=oi.organization_id and p.company_id=oi.company_id;

grant select on public.report_trial_balance,public.report_profit_loss,public.report_balance_sheet,public.report_day_book,public.report_stock_summary,public.report_tax_summary,public.report_receivable_payable_ageing to authenticated;

create index if not exists transactions_org_company_status_date_idx on public.transactions(organization_id,company_id,status,transaction_date desc);
create index if not exists transactions_org_company_party_idx on public.transactions(organization_id,company_id,party_id);
create index if not exists transactions_vehicle_idx on public.transactions(vehicle_id) where vehicle_id is not null;
create index if not exists transactions_service_job_idx on public.transactions(service_job_id) where service_job_id is not null;
create index if not exists transaction_lines_tx_company_idx on public.transaction_lines(transaction_id,company_id);
create index if not exists journals_tx_company_idx on public.journals(transaction_id,company_id);
create index if not exists journal_lines_journal_company_idx on public.journal_lines(journal_id,company_id);
create index if not exists journal_lines_account_company_idx on public.journal_lines(account_id,company_id);
create index if not exists parties_org_company_status_idx on public.parties(organization_id,company_id,status);
create index if not exists vehicles_org_company_customer_idx on public.vehicles(organization_id,company_id,customer_id);
create index if not exists vehicles_plate_idx on public.vehicles(organization_id,company_id,plate_number) where plate_number is not null;
create index if not exists products_org_company_status_idx on public.products(organization_id,company_id,status);
create index if not exists products_org_company_sku_idx on public.products(organization_id,company_id,sku) where sku is not null;
create index if not exists warehouses_org_company_branch_idx on public.warehouses(organization_id,company_id,branch_id);
create index if not exists stock_balances_org_company_warehouse_idx on public.stock_balances(organization_id,company_id,warehouse_id);
create index if not exists stock_movements_org_company_product_idx on public.stock_movements(organization_id,company_id,product_id,warehouse_id,created_at desc);
create index if not exists open_items_org_company_party_status_idx on public.open_items(organization_id,company_id,party_id,status,due_date);
create index if not exists allocations_open_item_idx on public.allocations(open_item_id);
create index if not exists service_jobs_org_company_status_idx on public.service_jobs(organization_id,company_id,status,opened_date desc);
create index if not exists service_jobs_vehicle_idx on public.service_jobs(vehicle_id) where vehicle_id is not null;
create index if not exists service_job_items_job_idx on public.service_job_items(service_job_id,organization_id);
create index if not exists service_job_status_history_job_idx on public.service_job_status_history(service_job_id,changed_at desc);
create index if not exists party_contacts_party_idx on public.party_contacts(party_id,organization_id);
create index if not exists party_addresses_party_idx on public.party_addresses(party_id,organization_id);
create index if not exists party_notes_party_idx on public.party_notes(party_id,organization_id,created_at desc);
create index if not exists product_prices_product_idx on public.product_prices(product_id,organization_id,effective_from desc);
create index if not exists product_categories_org_company_idx on public.product_categories(organization_id,company_id,status);
create index if not exists attachments_org_company_entity_idx on public.attachments(organization_id,company_id,entity_type,entity_id,deleted_at);
create index if not exists document_snapshots_tx_idx on public.document_snapshots(transaction_id,organization_id);
create index if not exists branches_org_company_idx on public.branches(organization_id,company_id,status);;
