-- 20260923075627  phase3_restore_bypass_hardening
-- Applied to Supabase project pwzpljitxamthgqllgtu


/* The restore bypass now needs BOTH:
     - the transaction-local flag, which only a SECURITY DEFINER function sets, and
     - the temporary id-map table that only restore_business_backup creates.
   A normal API request cannot create a temp table, so it can never take this path.
   The flag is transaction-local (set_config(...,true)), so it cannot leak into
   any later request on a pooled connection. */
create or replace function private.in_verified_restore() returns boolean
language plpgsql stable set search_path='' as $$
begin
  if coalesce(current_setting('app.restore_in_progress', true),'') <> '1' then return false; end if;
  return to_regclass('pg_temp._rmap') is not null;
end $$;
revoke all on function private.in_verified_restore() from public, anon, authenticated;

create or replace function private.guard_posted_transaction_media() returns trigger language plpgsql set search_path='' as $$
declare v_status text;
begin
  if private.in_verified_restore() then return coalesce(new,old); end if;
  select status into v_status from public.transactions where id=coalesce(new.transaction_id,old.transaction_id);
  if v_status in ('posted','void') then raise exception 'photos on a posted invoice cannot be changed'; end if;
  return coalesce(new,old);
end $$;

create or replace function private.audit_row() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if private.in_verified_restore() then return null; end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(coalesce(new.organization_id,old.organization_id),auth.uid(),tg_argv[0]||'.'||lower(tg_op),tg_argv[0],
    coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id',to_jsonb(new)->>'product_id'),
    case when tg_op<>'INSERT' then to_jsonb(old) end, case when tg_op<>'DELETE' then to_jsonb(new) end);
  return null;
end $$;
;
