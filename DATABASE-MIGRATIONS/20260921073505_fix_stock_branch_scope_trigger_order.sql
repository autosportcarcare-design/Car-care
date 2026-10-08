-- 20260921073505  fix_stock_branch_scope_trigger_order
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.fill_branch_scope() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_branch uuid; v_company uuid; v_parent uuid;
begin
  if tg_table_name='stock_movements' then
    v_parent:=nullif(to_jsonb(new)->>'transaction_id','')::uuid;
    if v_parent is not null then select branch_id,company_id into v_branch,v_company from public.transactions where id=v_parent and organization_id=new.organization_id; end if;
    new.company_id:=coalesce(new.company_id,v_company,private.default_company_id(new.organization_id));
  else
    v_branch:=new.branch_id;
    v_company:=new.company_id;
  end if;
  new.branch_id:=coalesce(v_branch,new.branch_id,private.default_branch_id(new.organization_id,new.company_id));
  if new.branch_id is not null and not exists(select 1 from public.branches b where b.id=new.branch_id and b.organization_id=new.organization_id and b.company_id=new.company_id and b.status='active') then raise exception 'Branch does not belong to company'; end if;
  return new;
end $$;;
