-- 20260919075432  v2_performance_fk_indexes_and_rls_cleanup_v2
-- Applied to Supabase project pwzpljitxamthgqllgtu

do $$
declare r record; idx_name text; cols text; covered boolean;
begin
  for r in
    select c.oid,c.conname,c.conrelid as relid,c.conrelid::regclass as tbl,c.conkey
    from pg_constraint c join pg_namespace n on n.oid=c.connamespace
    where c.contype='f' and n.nspname='public'
  loop
    select exists(
      select 1 from pg_index i
      where i.indrelid=r.relid and i.indisvalid
        and (i.indkey::smallint[] @> r.conkey) and (r.conkey @> i.indkey::smallint[])
    ) into covered;
    if not covered then
      select string_agg(quote_ident(a.attname),', ' order by u.ord)
        into cols
      from unnest(r.conkey) with ordinality as u(attnum,ord)
      join pg_attribute a on a.attrelid=r.relid and a.attnum=u.attnum;
      idx_name:='fk_'||substr(md5(r.conname),1,16)||'_idx';
      execute format('create index if not exists %I on %s (%s)',idx_name,r.tbl,cols);
    end if;
  end loop;
end $$;

drop policy if exists members_write on public.organization_members;
create policy members_insert on public.organization_members for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy members_update on public.organization_members for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy members_delete on public.organization_members for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));

drop policy if exists roles_write on public.organization_roles;
create policy roles_insert on public.organization_roles for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy roles_update on public.organization_roles for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy roles_delete on public.organization_roles for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));

drop policy if exists role_perm_write on public.organization_role_permissions;
create policy role_perm_insert on public.organization_role_permissions for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy role_perm_update on public.organization_role_permissions for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy role_perm_delete on public.organization_role_permissions for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));

drop policy if exists warehouse_write on public.warehouses;
create policy warehouse_insert on public.warehouses for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy warehouse_update on public.warehouses for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy warehouse_delete on public.warehouses for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

drop policy if exists tax_write on public.tax_codes;
create policy tax_insert on public.tax_codes for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy tax_update on public.tax_codes for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy tax_delete on public.tax_codes for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

drop policy if exists accounts_write on public.accounts;
create policy accounts_insert on public.accounts for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy accounts_update on public.accounts for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy accounts_delete on public.accounts for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

drop policy if exists payment_methods_write on public.payment_methods;
create policy payment_methods_insert on public.payment_methods for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy payment_methods_update on public.payment_methods for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy payment_methods_delete on public.payment_methods for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

drop policy if exists sequences_write on public.document_sequences;
create policy sequences_insert on public.document_sequences for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy sequences_update on public.document_sequences for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy sequences_delete on public.document_sequences for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

drop policy if exists profiles_write on public.document_profiles;
create policy profiles_insert on public.document_profiles for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'documents.design'));
create policy profiles_update on public.document_profiles for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'documents.design')) with check (private.has_permission(organization_id,(select auth.uid()),'documents.design'));
create policy profiles_delete on public.document_profiles for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'documents.design'));

drop policy if exists periods_write on public.accounting_periods;
create policy periods_insert on public.accounting_periods for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy periods_update on public.accounting_periods for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy periods_delete on public.accounting_periods for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));;
