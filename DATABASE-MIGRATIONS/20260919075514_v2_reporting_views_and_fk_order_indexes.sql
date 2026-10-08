-- 20260919075514  v2_reporting_views_and_fk_order_indexes
-- Applied to Supabase project pwzpljitxamthgqllgtu

create index if not exists allocations_open_item_org_fk_idx on public.allocations(open_item_id, organization_id);
create index if not exists journal_lines_account_org_fk_idx on public.journal_lines(account_id, organization_id);
create index if not exists transaction_lines_tx_org_fk_idx on public.transaction_lines(transaction_id, organization_id);

create view public.report_trial_balance with (security_invoker=true) as
select a.organization_id,a.id as account_id,a.code,a.name,a.account_type,
       round(coalesce(sum(jl.debit),0),2) as debit,
       round(coalesce(sum(jl.credit),0),2) as credit,
       round(coalesce(sum(jl.debit-jl.credit),0),2) as balance
from public.accounts a
left join public.journal_lines jl on jl.organization_id=a.organization_id and jl.account_id=a.id
left join public.journals j on j.id=jl.journal_id and j.organization_id=jl.organization_id
group by a.organization_id,a.id,a.code,a.name,a.account_type;

create view public.report_profit_loss with (security_invoker=true) as
select tb.organization_id,tb.account_id,tb.code,tb.name,tb.account_type,
       case when tb.account_type='income' then round(tb.credit-tb.debit,2)
            when tb.account_type in ('cogs','expense') then round(tb.debit-tb.credit,2)
            else 0 end as amount
from public.report_trial_balance tb
where tb.account_type in ('income','cogs','expense');

create view public.report_balance_sheet with (security_invoker=true) as
select tb.organization_id,tb.account_id,tb.code,tb.name,tb.account_type,
       case when tb.account_type='asset' then round(tb.debit-tb.credit,2)
            when tb.account_type in ('liability','equity') then round(tb.credit-tb.debit,2)
            else 0 end as amount
from public.report_trial_balance tb
where tb.account_type in ('asset','liability','equity');

create view public.report_stock_summary with (security_invoker=true) as
select sb.organization_id,sb.product_id,p.sku,p.name as product_name,sb.warehouse_id,w.code as warehouse_code,w.name as warehouse_name,
       sb.quantity,sb.average_cost,round(sb.quantity*sb.average_cost,2) as stock_value
from public.stock_balances sb
join public.products p on p.id=sb.product_id and p.organization_id=sb.organization_id
join public.warehouses w on w.id=sb.warehouse_id and w.organization_id=sb.organization_id;

create view public.report_receivable_payable_ageing with (security_invoker=true) as
select oi.organization_id,oi.id as open_item_id,oi.transaction_id,oi.party_id,p.name as party_name,oi.item_type,
       oi.original_amount,oi.allocated_amount,round(oi.original_amount-oi.allocated_amount,2) as outstanding,
       oi.due_date,oi.status,
       greatest(current_date-coalesce(oi.due_date,current_date),0) as overdue_days,
       case
         when oi.status in ('settled','void') then 'Closed'
         when coalesce(oi.due_date,current_date)>=current_date then 'Current'
         when current_date-oi.due_date between 1 and 30 then '1-30'
         when current_date-oi.due_date between 31 and 60 then '31-60'
         when current_date-oi.due_date between 61 and 90 then '61-90'
         else '90+'
       end as ageing_bucket
from public.open_items oi
join public.parties p on p.id=oi.party_id and p.organization_id=oi.organization_id;

create view public.report_tax_summary with (security_invoker=true) as
select t.organization_id,
       round(coalesce(sum(case when t.transaction_type in ('sale','service_sale','mixed_sale') and t.status='posted' then l.line_tax else 0 end),0),2) as output_tax,
       round(coalesce(sum(case when t.transaction_type in ('purchase','expense') and t.status='posted' and coalesce(l.input_tax_recoverable,false) then l.line_tax else 0 end),0),2) as input_tax,
       round(
         coalesce(sum(case when t.transaction_type in ('sale','service_sale','mixed_sale') and t.status='posted' then l.line_tax else 0 end),0)
         - coalesce(sum(case when t.transaction_type in ('purchase','expense') and t.status='posted' and coalesce(l.input_tax_recoverable,false) then l.line_tax else 0 end),0)
       ,2) as net_tax
from public.transactions t
join public.transaction_lines l on l.transaction_id=t.id and l.organization_id=t.organization_id
group by t.organization_id;

create view public.report_day_book with (security_invoker=true) as
select t.organization_id,t.id as transaction_id,t.document_no,t.transaction_type,t.transaction_date,t.party_id,p.name as party_name,t.status,t.subtotal,t.tax_total,t.grand_total,t.balance_total,t.created_at,t.posted_at
from public.transactions t
left join public.parties p on p.id=t.party_id and p.organization_id=t.organization_id;

grant select on public.report_trial_balance,public.report_profit_loss,public.report_balance_sheet,public.report_stock_summary,public.report_receivable_payable_ageing,public.report_tax_summary,public.report_day_book to authenticated;;
