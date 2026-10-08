-- 20260921065252  phase2_members_roles_rpc
-- Applied to Supabase project pwzpljitxamthgqllgtu


create or replace function private.company_members(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_org_member(p_org,auth.uid()) then raise exception 'permission denied'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email,'role_id',m.role_id,'role',r.name,
      'status',m.status,'since',m.created_at,'me',m.user_id=auth.uid()) order by r.name,u.email)
    from public.organization_members m join public.organization_roles r on r.id=m.role_id left join auth.users u on u.id=m.user_id
    where m.organization_id=p_org),'[]'::jsonb);
end $$;

create or replace function private.company_roles(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_org_member(p_org,auth.uid()) then raise exception 'permission denied'; end if;
  return jsonb_build_object(
    'roles',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'system',r.is_system,
        'permissions',coalesce((select jsonb_agg(rp.permission_key order by rp.permission_key) from public.organization_role_permissions rp where rp.role_id=r.id),'[]'::jsonb))
        order by case r.name when 'Owner' then 1 when 'Admin' then 2 when 'Manager' then 3 when 'Accountant' then 4 when 'Staff' then 5 else 6 end, r.name)
      from public.organization_roles r where r.organization_id=p_org),'[]'::jsonb),
    'catalog',(select jsonb_agg(jsonb_build_object('key',key,'label',description) order by key) from public.permission_catalog));
end $$;

create or replace function private.add_member_by_email(p_org uuid, p_email text, p_role uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_role text;
begin
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'permission denied: manage users'; end if;
  select name into v_role from public.organization_roles where id=p_role and organization_id=p_org;
  if v_role is null then raise exception 'role not found in this company'; end if;
  if v_role='Owner' and not exists (select 1 from public.organization_members m join public.organization_roles r on r.id=m.role_id
     where m.organization_id=p_org and m.user_id=v_uid and r.name='Owner') then raise exception 'only an Owner can add another Owner'; end if;
  select id into v_target from auth.users where lower(email)=lower(trim(p_email));
  if v_target is null then raise exception 'no account uses %. Ask them to create an account first, then add them here.', trim(p_email); end if;
  insert into public.organization_members(organization_id,user_id,role_id,status) values(p_org,v_target,p_role,'active')
  on conflict (organization_id,user_id) do update set role_id=excluded.role_id,status='active',updated_at=now();
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'member.added','member',v_target::text,jsonb_build_object('email',lower(trim(p_email)),'role',v_role));
  return jsonb_build_object('user_id',v_target,'role',v_role);
end $$;

create or replace function private.set_member_role(p_org uuid, p_user uuid, p_role uuid, p_status text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_old_role text; v_new_role text; v_old_status text; v_owners int;
begin
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'permission denied: manage users'; end if;
  if p_status not in ('active','suspended') then raise exception 'status must be active or suspended'; end if;
  select r.name,m.status into v_old_role,v_old_status from public.organization_members m join public.organization_roles r on r.id=m.role_id
   where m.organization_id=p_org and m.user_id=p_user for update of m;
  if v_old_role is null then raise exception 'member not found'; end if;
  select name into v_new_role from public.organization_roles where id=p_role and organization_id=p_org;
  if v_new_role is null then raise exception 'role not found in this company'; end if;
  if (v_old_role='Owner' or v_new_role='Owner') and not exists (select 1 from public.organization_members m join public.organization_roles r on r.id=m.role_id
     where m.organization_id=p_org and m.user_id=v_uid and r.name='Owner' and m.status='active') then raise exception 'only an Owner can change Owner access'; end if;
  if v_old_role='Owner' and (v_new_role<>'Owner' or p_status<>'active') then
    select count(*) into v_owners from public.organization_members m join public.organization_roles r on r.id=m.role_id
     where m.organization_id=p_org and r.name='Owner' and m.status='active';
    if v_owners<=1 then raise exception 'a company must keep at least one active Owner'; end if;
  end if;
  update public.organization_members set role_id=p_role,status=p_status,updated_at=now() where organization_id=p_org and user_id=p_user;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,previous_values,new_values)
  values(p_org,v_uid,'permission.member_changed','member',p_user::text,jsonb_build_object('role',v_old_role,'status',v_old_status),jsonb_build_object('role',v_new_role,'status',p_status));
  return jsonb_build_object('role',v_new_role,'status',p_status);
end $$;

create or replace function private.set_role_permission(p_org uuid, p_role uuid, p_permission text, p_on boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_role text;
begin
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'permission denied: manage roles'; end if;
  select name into v_role from public.organization_roles where id=p_role and organization_id=p_org;
  if v_role is null then raise exception 'role not found in this company'; end if;
  if v_role='Owner' then raise exception 'the Owner role always has every permission'; end if;
  if not exists (select 1 from public.permission_catalog where key=p_permission) then raise exception 'unknown permission'; end if;
  if p_on then
    insert into public.organization_role_permissions(organization_id,role_id,permission_key) values(p_org,p_role,p_permission) on conflict do nothing;
  else
    delete from public.organization_role_permissions where organization_id=p_org and role_id=p_role and permission_key=p_permission;
  end if;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'permission.role_changed','role',p_role::text,jsonb_build_object('role',v_role,'permission',p_permission,'granted',p_on));
  return exists (select 1 from public.organization_role_permissions where role_id=p_role and permission_key=p_permission);
end $$;

create or replace function private.create_role(p_org uuid, p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_id uuid;
begin
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'permission denied: manage roles'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'role name required'; end if;
  insert into public.organization_roles(organization_id,name,is_system) values(p_org,trim(p_name),false) returning id into v_id;
  insert into public.organization_role_permissions(organization_id,role_id,permission_key) values(p_org,v_id,'organization.view'),(p_org,v_id,'masters.view');
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
  values(p_org,v_uid,'permission.role_created','role',v_id::text,jsonb_build_object('name',trim(p_name)));
  return v_id;
exception when unique_violation then raise exception 'a role called % already exists', trim(p_name);
end $$;

create or replace function public.company_members(p_org uuid) returns jsonb language sql stable set search_path='' as $$ select private.company_members($1); $$;
create or replace function public.company_roles(p_org uuid) returns jsonb language sql stable set search_path='' as $$ select private.company_roles($1); $$;
create or replace function public.add_member_by_email(p_org uuid, p_email text, p_role uuid) returns jsonb language sql set search_path='' as $$ select private.add_member_by_email($1,$2,$3); $$;
create or replace function public.set_member_role(p_org uuid, p_user uuid, p_role uuid, p_status text) returns jsonb language sql set search_path='' as $$ select private.set_member_role($1,$2,$3,$4); $$;
create or replace function public.set_role_permission(p_org uuid, p_role uuid, p_permission text, p_on boolean) returns boolean language sql set search_path='' as $$ select private.set_role_permission($1,$2,$3,$4); $$;
create or replace function public.create_role(p_org uuid, p_name text) returns uuid language sql set search_path='' as $$ select private.create_role($1,$2); $$;

revoke all on function public.company_members(uuid), public.company_roles(uuid), public.add_member_by_email(uuid,text,uuid),
  public.set_member_role(uuid,uuid,uuid,text), public.set_role_permission(uuid,uuid,text,boolean), public.create_role(uuid,text) from public, anon;
grant execute on function public.company_members(uuid), public.company_roles(uuid), public.add_member_by_email(uuid,text,uuid),
  public.set_member_role(uuid,uuid,uuid,text), public.set_role_permission(uuid,uuid,text,boolean), public.create_role(uuid,text) to authenticated;
;
