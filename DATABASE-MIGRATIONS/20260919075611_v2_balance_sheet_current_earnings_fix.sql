-- 20260919075611  v2_balance_sheet_current_earnings_fix
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace view public.report_balance_sheet with (security_invoker=true) as
select tb.organization_id,tb.account_id,tb.code,tb.name,tb.account_type,
       case when tb.account_type='asset' then round(tb.debit-tb.credit,2)
            when tb.account_type in ('liability','equity') then round(tb.credit-tb.debit,2)
            else 0 end as amount
from public.report_trial_balance tb
where tb.account_type in ('asset','liability','equity')
union all
select pl.organization_id,null::uuid as account_id,'CURRENT_EARNINGS'::text as code,'Current Earnings'::text as name,'equity'::text as account_type,
       round(sum(case when pl.account_type='income' then pl.amount when pl.account_type in ('cogs','expense') then -pl.amount else 0 end),2) as amount
from public.report_profit_loss pl
group by pl.organization_id;;
