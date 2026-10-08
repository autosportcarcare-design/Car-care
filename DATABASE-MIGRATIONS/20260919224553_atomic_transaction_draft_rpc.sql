-- 20260919224553  atomic_transaction_draft_rpc
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.save_transaction_draft(
  p_organization_id uuid,
  p_transaction jsonb,
  p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_existing public.transactions%rowtype;
  v_settings public.organization_settings%rowtype;
  v_type text;
  v_date date;
  v_due date;
  v_party uuid;
  v_warehouse uuid;
  v_payment_method uuid;
  v_profile uuid;
  v_profile_version uuid;
  v_notes text;
  v_negative_confirmed boolean;
  v_line jsonb;
  v_line_no integer := 0;
  v_product uuid;
  v_line_warehouse uuid;
  v_description text;
  v_qty numeric;
  v_unit_price numeric;
  v_discount numeric;
  v_tax_code uuid;
  v_recoverable boolean;
  v_direct_cost numeric;
  v_tax public.tax_codes%rowtype;
  v_rate numeric := 0;
  v_class text := 'out_of_scope';
  v_inclusive boolean := false;
  v_base numeric;
  v_net numeric;
  v_tax_amount numeric;
  v_total numeric;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_tax_total numeric := 0;
  v_grand_total numeric := 0;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_organization_id is null or not private.is_org_member(p_organization_id,v_uid) then raise exception 'organization access denied'; end if;
  if not private.has_permission(p_organization_id,v_uid,'transaction.create') then raise exception 'transaction create permission denied'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines)=0 then raise exception 'at least one transaction line is required'; end if;

  v_type := nullif(trim(p_transaction->>'transaction_type'),'');
  if v_type not in ('sale','service_sale','mixed_sale','purchase','quotation','expense','receipt','payment','income','capital','drawing') then
    raise exception 'transaction type % is not enabled for draft entry',coalesce(v_type,'null');
  end if;
  v_date := coalesce(nullif(p_transaction->>'transaction_date','')::date,current_date);
  v_due := nullif(p_transaction->>'due_date','')::date;
  v_party := nullif(p_transaction->>'party_id','')::uuid;
  v_warehouse := nullif(p_transaction->>'warehouse_id','')::uuid;
  v_payment_method := nullif(p_transaction->>'payment_method_id','')::uuid;
  v_profile := nullif(p_transaction->>'document_profile_id','')::uuid;
  v_profile_version := nullif(p_transaction->>'document_profile_version_id','')::uuid;
  v_notes := nullif(trim(p_transaction->>'notes'),'');
  v_negative_confirmed := coalesce((p_transaction->>'negative_stock_confirmed')::boolean,false);

  select * into v_settings from public.organization_settings where organization_id=p_organization_id;
  if not found then raise exception 'organization settings missing'; end if;

  if p_transaction ? 'id' and nullif(p_transaction->>'id','') is not null then
    v_id := (p_transaction->>'id')::uuid;
    select * into v_existing from public.transactions where id=v_id and organization_id=p_organization_id for update;
    if not found then raise exception 'draft transaction not found'; end if;
    if v_existing.status <> 'draft' then raise exception 'only draft transactions can be edited'; end if;
    if not private.has_permission(p_organization_id,v_uid,'transaction.edit') then raise exception 'transaction edit permission denied'; end if;
    delete from public.transaction_lines where organization_id=p_organization_id and transaction_id=v_id;
    update public.transactions set
      transaction_type=v_type,transaction_date=v_date,due_date=v_due,party_id=v_party,warehouse_id=v_warehouse,
      payment_method_id=v_payment_method,currency=v_settings.currency,notes=v_notes,document_profile_id=v_profile,
      document_profile_version_id=v_profile_version,negative_stock_confirmed=v_negative_confirmed,needs_review=false,updated_at=now()
    where id=v_id and organization_id=p_organization_id;
  else
    insert into public.transactions(
      organization_id,transaction_type,transaction_date,due_date,party_id,warehouse_id,payment_method_id,
      status,currency,notes,document_profile_id,document_profile_version_id,negative_stock_confirmed,created_by
    ) values (
      p_organization_id,v_type,v_date,v_due,v_party,v_warehouse,v_payment_method,'draft',v_settings.currency,v_notes,
      v_profile,v_profile_version,v_negative_confirmed,v_uid
    ) returning id into v_id;
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_line_no := v_line_no + 1;
    v_product := nullif(v_line->>'product_id','')::uuid;
    v_line_warehouse := coalesce(nullif(v_line->>'warehouse_id','')::uuid,v_warehouse);
    v_description := trim(coalesce(v_line->>'description',''));
    v_qty := coalesce(nullif(v_line->>'quantity','')::numeric,0);
    v_unit_price := coalesce(nullif(v_line->>'unit_price','')::numeric,0);
    v_discount := coalesce(nullif(v_line->>'discount_amount','')::numeric,0);
    v_tax_code := nullif(v_line->>'tax_code_id','')::uuid;
    v_recoverable := case when v_line ? 'input_tax_recoverable' and v_line->>'input_tax_recoverable' <> '' then (v_line->>'input_tax_recoverable')::boolean else null end;
    v_direct_cost := coalesce(nullif(v_line->>'direct_cost_snapshot','')::numeric,0);

    if v_description='' then raise exception 'line % description required',v_line_no; end if;
    if v_qty<=0 then raise exception 'line % quantity must be greater than zero',v_line_no; end if;
    if v_unit_price<0 or v_discount<0 then raise exception 'line % values cannot be negative',v_line_no; end if;
    v_base := round((v_qty*v_unit_price-v_discount)::numeric,2);
    if v_base<0 then raise exception 'line % discount exceeds line value',v_line_no; end if;

    v_rate:=0; v_class:='out_of_scope'; v_inclusive:=false;
    if v_settings.tax_enabled and v_tax_code is not null then
      select * into v_tax from public.tax_codes
      where id=v_tax_code and organization_id=p_organization_id and status='active'
        and effective_from<=v_date and (effective_to is null or effective_to>=v_date);
      if not found then raise exception 'line % tax code is not effective for transaction date',v_line_no; end if;
      v_rate:=v_tax.rate; v_class:=v_tax.classification; v_inclusive:=v_tax.inclusive;
      if v_recoverable is null then v_recoverable:=v_tax.input_recoverable_default; end if;
    else
      v_recoverable:=false;
    end if;

    if v_inclusive and v_rate>0 then
      v_total:=v_base;
      v_net:=round(v_base/(1+(v_rate/100)),2);
      v_tax_amount:=round(v_total-v_net,2);
    else
      v_net:=v_base;
      v_tax_amount:=round(v_net*(v_rate/100),2);
      v_total:=round(v_net+v_tax_amount,2);
    end if;

    insert into public.transaction_lines(
      organization_id,transaction_id,line_no,product_id,warehouse_id,description,quantity,unit_price,discount_amount,
      tax_code_id,tax_rate,tax_classification,tax_inclusive,input_tax_recoverable,line_net,line_tax,line_total,direct_cost_snapshot
    ) values (
      p_organization_id,v_id,v_line_no,v_product,v_line_warehouse,v_description,v_qty,v_unit_price,v_discount,
      v_tax_code,v_rate,v_class,v_inclusive,v_recoverable,v_net,v_tax_amount,v_total,v_direct_cost
    );

    v_subtotal:=v_subtotal+v_net;
    v_discount_total:=v_discount_total+v_discount;
    v_tax_total:=v_tax_total+v_tax_amount;
    v_grand_total:=v_grand_total+v_total;
  end loop;

  update public.transactions set
    subtotal=round(v_subtotal,2),discount_total=round(v_discount_total,2),tax_total=round(v_tax_total,2),
    grand_total=round(v_grand_total,2),balance_total=round(v_grand_total,2),updated_at=now()
  where id=v_id and organization_id=p_organization_id;

  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_organization_id,v_uid,case when p_transaction ? 'id' then 'transaction.draft_updated' else 'transaction.draft_created' end,
         'transaction',v_id::text,jsonb_build_object('transaction_type',v_type,'line_count',v_line_no,'grand_total',round(v_grand_total,2)));
  return v_id;
end;
$$;

create or replace function public.save_transaction_draft(p_organization_id uuid,p_transaction jsonb,p_lines jsonb)
returns uuid language sql security invoker set search_path=''
as $$ select private.save_transaction_draft($1,$2,$3); $$;
revoke all on function public.save_transaction_draft(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.save_transaction_draft(uuid,jsonb,jsonb) to authenticated;;
