-- 20260919075306  v2_security_hardening_rpc_wrappers
-- Applied to Supabase project pwzpljitxamthgqllgtu

alter table public.permission_catalog enable row level security;
create policy permission_catalog_read on public.permission_catalog for select to authenticated using (true);
create policy posting_requests_select on public.posting_requests for select to authenticated using (created_by=(select auth.uid()) and private.is_org_member(organization_id,(select auth.uid())));

alter function public.create_organization(text,text) set schema private;
alter function public.post_transaction(uuid,text) set schema private;
alter function public.allocate_open_item(uuid,uuid,numeric) set schema private;
alter function public.void_transaction(uuid,text) set schema private;

revoke all on function private.create_organization(text,text), private.post_transaction(uuid,text), private.allocate_open_item(uuid,uuid,numeric), private.void_transaction(uuid,text) from public, anon;
grant execute on function private.create_organization(text,text), private.post_transaction(uuid,text), private.allocate_open_item(uuid,uuid,numeric), private.void_transaction(uuid,text) to authenticated;

create or replace function public.create_organization(p_name text,p_currency text default 'USD')
returns uuid language sql security invoker set search_path='' as $$ select private.create_organization($1,$2); $$;
create or replace function public.post_transaction(p_transaction_id uuid,p_idempotency_key text)
returns jsonb language sql security invoker set search_path='' as $$ select private.post_transaction($1,$2); $$;
create or replace function public.allocate_open_item(p_payment_transaction_id uuid,p_open_item_id uuid,p_amount numeric)
returns uuid language sql security invoker set search_path='' as $$ select private.allocate_open_item($1,$2,$3); $$;
create or replace function public.void_transaction(p_transaction_id uuid,p_idempotency_key text)
returns jsonb language sql security invoker set search_path='' as $$ select private.void_transaction($1,$2); $$;

revoke all on function public.create_organization(text,text), public.post_transaction(uuid,text), public.allocate_open_item(uuid,uuid,numeric), public.void_transaction(uuid,text) from public, anon;
grant execute on function public.create_organization(text,text), public.post_transaction(uuid,text), public.allocate_open_item(uuid,uuid,numeric), public.void_transaction(uuid,text) to authenticated;;
