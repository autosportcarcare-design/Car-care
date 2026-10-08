-- 20260922221715  phase3_restore_business_backup
-- Applied to Supabase project pwzpljitxamthgqllgtu


create or replace function private.restore_business_backup(p_backup jsonb, p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
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
  delete from _rmap;
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
  values(v_new_org,'restore','ready',coalesce(p_backup->>'schema_version','unknown'),
    jsonb_build_object('restored_from_organization',v_old_org,'source_backup_id',p_backup->>'backup_id','source_created_at',p_backup->>'created_at','verification',v_report,'binary_files_copied',false),v_uid,now(),now());
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(v_new_org,v_uid,'backup.restored','organization',v_new_org::text,jsonb_build_object('source_organization',v_old_org,'verification',v_report));
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  select v_old_org,v_uid,'backup.restored_to_new_company','organization',v_new_org::text,jsonb_build_object('restored_organization',v_new_org)
  where exists (select 1 from public.organizations where id=v_old_org);

  return jsonb_build_object('verified',true,'organization_id',v_new_org,'name',v_name,'verification',v_report);
end $$;

/* Inserts one backup section, remapping every old id to its new id
   (including ids inside jsonb snapshots) and dropping links that are filled later. */
create or replace function private.restore_rows(p_backup jsonb, p_key text, p_table text, p_org uuid, p_defer text[]) returns void
language plpgsql security definer set search_path='' as $$
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
end $$;

create or replace function public.restore_business_backup(p_backup jsonb, p_name text) returns jsonb language sql set search_path='' as $$ select private.restore_business_backup($1,$2) $$;
revoke all on function public.restore_business_backup(jsonb,text) from public, anon;
grant execute on function public.restore_business_backup(jsonb,text) to authenticated;
;
