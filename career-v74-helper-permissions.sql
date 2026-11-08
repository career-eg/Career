-- CareerK v74 — Helper permissions (team roles)
-- Each helper (pharmacists.is_helper = true) gets a list of permissions picked by the admin.
-- Helpers log into admin.careerk.net with their own CareerK account and can ONLY do what
-- their permissions allow. Everything a helper changes is written to helper_activity.
--
-- Permission keys:
--   verify          مراجعة التوثيق (قبول/رفض/تذكير — صيادلة وصيدليات)
--   members         إظهار/إخفاء الأعضاء وحذف الصور
--   jobs            إيقاف/تشغيل/حذف الوظايف
--   sales           إيقاف/تشغيل/حذف إعلانات البيع
--   otp             أكواد استعادة الباسورد
--   resets          طلبات الاستعادة (قبول/رفض)
--   notify          إرسال الإشعارات
--   moderation      حظر/فك حظر الأرقام + تغيير باسورد عضو
--   delete_accounts حذف الحسابات (وحذف + حظر)
--   contacts        أرقام التواصل
-- Admin-only (never delegable): helpers & permissions, admin password.
-- Safe to re-run.

-- =============================================================
-- 0) Columns
-- =============================================================
alter table public.pharmacists
  add column if not exists is_helper          boolean not null default false,
  add column if not exists helper_note        text,
  add column if not exists helper_permissions text[] not null default '{}';

-- =============================================================
-- 1) Who am I?
-- =============================================================
create or replace function public.is_real_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.managers where user_id = auth.uid() and is_active = true);
$$;

create or replace function public.helper_can(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.pharmacists
    where user_id = auth.uid() and is_helper = true and p = any(helper_permissions)
  );
$$;

-- Admin check used by the admin RPCs. We keep the ORIGINAL function untouched
-- (renamed to is_current_user_admin_base — existing RLS policies keep pointing at it),
-- and put a thin wrapper in its place: a helper counts as admin ONLY inside
-- helper_exec() below, which sets careerk.helper_perm for that one transaction
-- after checking the helper really has that permission.
do $$
begin
  if to_regprocedure('public.is_current_user_admin_base()') is null then
    if to_regprocedure('public.is_current_user_admin()') is not null then
      alter function public.is_current_user_admin() rename to is_current_user_admin_base;
    else
      create function public.is_current_user_admin_base() returns boolean language sql stable security definer
        set search_path = public as 'select exists(select 1 from public.managers where user_id = auth.uid() and is_active = true)';
    end if;
  end if;
end $$;

create or replace function public.is_current_user_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_current_user_admin_base()
      or (coalesce(current_setting('careerk.helper_perm', true), '') <> ''
          and public.helper_can(current_setting('careerk.helper_perm', true)));
$$;
grant execute on function public.is_current_user_admin() to anon, authenticated;

create or replace function public.my_helper_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'full_name', full_name, 'permissions', helper_permissions, 'note', helper_note)
  from public.pharmacists where user_id = auth.uid() and is_helper = true limit 1;
$$;
grant execute on function public.is_real_admin()       to authenticated;
grant execute on function public.helper_can(text)      to authenticated;
grant execute on function public.my_helper_profile()   to authenticated;

-- =============================================================
-- 2) Activity log
-- =============================================================
create table if not exists public.helper_activity (
  id           bigserial primary key,
  actor_id     uuid not null,
  actor_name   text,
  action       text not null,
  target_table text,
  target_id    text,
  details      jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists idx_helper_activity_created on public.helper_activity (created_at desc);
alter table public.helper_activity enable row level security;
drop policy if exists "admin_reads_helper_activity" on public.helper_activity;
create policy "admin_reads_helper_activity" on public.helper_activity for select to authenticated
  using (public.is_real_admin() or actor_id = auth.uid());
grant select on public.helper_activity to authenticated;

create or replace function public.log_helper(p_action text, p_table text, p_id text, p_details jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if auth.uid() is null or public.is_real_admin() then return; end if;
  select full_name into v_name from pharmacists where user_id = auth.uid() and is_helper limit 1;
  if not found then return; end if;
  insert into helper_activity (actor_id, actor_name, action, target_table, target_id, details)
  values (auth.uid(), v_name, p_action, p_table, p_id, p_details);
end $$;

-- generic row-change logger (only records changes made by helpers)
create or replace function public.trg_log_helper_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_row jsonb; v_old jsonb; v_changed jsonb := '{}'::jsonb; k text;
begin
  if auth.uid() is null or public.is_real_admin() then return coalesce(new, old); end if;
  if not exists (select 1 from pharmacists where user_id = auth.uid() and is_helper) then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' then
    v_row := to_jsonb(new); v_old := to_jsonb(old);
    -- never let a helper's own-profile edits spam the log
    if (v_row ->> 'user_id') = auth.uid()::text and tg_table_name = 'pharmacists' then return new; end if;
    for k in select jsonb_object_keys(v_row) loop
      if v_row -> k is distinct from v_old -> k and k not in ('updated_at') then
        v_changed := v_changed || jsonb_build_object(k, jsonb_build_array(v_old -> k, v_row -> k));
      end if;
    end loop;
    perform log_helper('update', tg_table_name, v_row ->> 'id', v_changed);
    return new;
  elsif tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    perform log_helper('delete', tg_table_name, v_old ->> 'id',
      jsonb_strip_nulls(jsonb_build_object('title', v_old ->> 'title', 'name', coalesce(v_old ->> 'full_name', v_old ->> 'name'), 'whatsapp', v_old ->> 'whatsapp')));
    return old;
  else
    v_row := to_jsonb(new);
    if (v_row ->> 'user_id') = auth.uid()::text then return new; end if;
    perform log_helper('insert', tg_table_name, v_row ->> 'id',
      jsonb_strip_nulls(jsonb_build_object('title', v_row ->> 'title', 'to', v_row ->> 'user_id')));
    return new;
  end if;
end $$;

-- =============================================================
-- 3) Guard: nobody but the admin can grant helper status/permissions,
--    owners can't self-verify, helpers can only touch the columns their role allows.
-- =============================================================
create or replace function public.trg_guard_member_row()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_allowed text[] := array['updated_at'];
  v_new jsonb; v_old jsonb;
begin
  if auth.uid() is null or public.is_current_user_admin() then return new; end if;

  if tg_table_name = 'pharmacists' then
    if new.is_helper is distinct from old.is_helper
       or new.helper_permissions is distinct from old.helper_permissions
       or new.helper_note is distinct from old.helper_note then
      raise exception 'only_admin_can_change_helpers';
    end if;
  end if;

  -- the member editing their own row
  if (to_jsonb(new) ->> 'user_id') = auth.uid()::text then
    if coalesce((to_jsonb(new) ->> 'is_verified')::boolean, false) and not coalesce((to_jsonb(old) ->> 'is_verified')::boolean, false) then
      raise exception 'cannot_self_verify';
    end if;
    if (to_jsonb(new) ->> 'verification_status') = 'verified' and (to_jsonb(old) ->> 'verification_status') is distinct from 'verified' then
      raise exception 'cannot_self_verify';
    end if;
    return new;
  end if;

  -- a helper editing someone else
  if public.helper_can('verify') then
    v_allowed := v_allowed || array['is_verified','verification_status','verification_note','verification_reject_reason','verified_at','verified_by'];
  end if;
  if public.helper_can('members') then
    v_allowed := v_allowed || array['looking_for_work','is_active','avatar_url','logo_url'];
  end if;
  v_new := to_jsonb(new) - v_allowed;
  v_old := to_jsonb(old) - v_allowed;
  if v_new is distinct from v_old then
    raise exception 'helper_not_allowed';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_pharmacists on public.pharmacists;
create trigger trg_guard_pharmacists before update on public.pharmacists
  for each row execute function public.trg_guard_member_row();
drop trigger if exists trg_guard_pharmacies on public.pharmacies;
create trigger trg_guard_pharmacies before update on public.pharmacies
  for each row execute function public.trg_guard_member_row();

-- =============================================================
-- 4) Helper RLS (policies are OR-ed with the existing ones)
-- =============================================================
-- members & verification
drop policy if exists "helpers_update_pharmacists" on public.pharmacists;
create policy "helpers_update_pharmacists" on public.pharmacists for update to authenticated
  using (public.helper_can('verify') or public.helper_can('members'))
  with check (public.helper_can('verify') or public.helper_can('members'));
drop policy if exists "helpers_update_pharmacies" on public.pharmacies;
create policy "helpers_update_pharmacies" on public.pharmacies for update to authenticated
  using (public.helper_can('verify') or public.helper_can('members'))
  with check (public.helper_can('verify') or public.helper_can('members'));
drop policy if exists "helpers_read_pharmacies" on public.pharmacies;
create policy "helpers_read_pharmacies" on public.pharmacies for select to authenticated
  using (public.helper_can('verify') or public.helper_can('members'));

-- jobs
drop policy if exists "helpers_manage_jobs" on public.jobs;
create policy "helpers_manage_jobs" on public.jobs for all to authenticated
  using (public.helper_can('jobs')) with check (public.helper_can('jobs'));

-- pharmacy sales
do $$ begin
  if to_regclass('public.pharmacy_sales') is not null then
    execute 'drop policy if exists "helpers_manage_sales" on public.pharmacy_sales';
    execute 'create policy "helpers_manage_sales" on public.pharmacy_sales for all to authenticated
             using (public.helper_can(''sales'')) with check (public.helper_can(''sales''))';
  end if;
end $$;

-- notifications: helpers who verify/notify/handle codes can message members
drop policy if exists "helpers_insert_notifications" on public.notifications;
create policy "helpers_insert_notifications" on public.notifications for insert to authenticated
  with check (public.helper_can('notify') or public.helper_can('verify') or public.helper_can('otp') or public.helper_can('resets'));
drop policy if exists "helpers_manage_notifications" on public.notifications;
create policy "helpers_manage_notifications" on public.notifications for all to authenticated
  using (public.helper_can('notify')) with check (public.helper_can('notify'));

-- password codes / reset requests
drop policy if exists "helpers_read_otp" on public.otp_codes;
create policy "helpers_read_otp" on public.otp_codes for select to authenticated
  using (public.helper_can('otp'));
do $$ begin
  if to_regclass('public.password_reset_requests') is not null then
    execute 'drop policy if exists "helpers_read_resets" on public.password_reset_requests';
    execute 'create policy "helpers_read_resets" on public.password_reset_requests for select to authenticated
             using (public.helper_can(''resets''))';
  end if;
  if to_regclass('public.blocked_phones') is not null then
    execute 'drop policy if exists "helpers_read_blocked" on public.blocked_phones';
    execute 'create policy "helpers_read_blocked" on public.blocked_phones for select to authenticated
             using (public.helper_can(''moderation''))';
  end if;
  if to_regclass('public.contact_numbers') is not null then
    execute 'drop policy if exists "helpers_manage_contacts" on public.contact_numbers';
    execute 'create policy "helpers_manage_contacts" on public.contact_numbers for all to authenticated
             using (public.helper_can(''contacts'')) with check (public.helper_can(''contacts''))';
  end if;
end $$;

-- activity triggers
do $$
declare t text;
begin
  foreach t in array array['pharmacists','pharmacies','jobs','pharmacy_sales','notifications','contact_numbers','otp_codes'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_helper_activity on public.%I', t);
      execute format('create trigger trg_helper_activity after insert or update or delete on public.%I
                      for each row execute function public.trg_log_helper_change()', t);
    end if;
  end loop;
end $$;

-- =============================================================
-- 5) helper_exec: run one whitelisted admin RPC as a helper
-- =============================================================
create or replace function public.helper_exec(p_fn text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_perm text;
  v_proc record;
  v_arglist text;
  v_result jsonb;
begin
  v_perm := case p_fn
    when 'admin_issue_reset_code'           then 'otp'
    when 'admin_issue_reset_code_by_phone'  then 'otp'
    when 'admin_approve_password_reset'     then 'resets'
    when 'admin_reject_password_reset'      then 'resets'
    when 'admin_block_phone'                then 'moderation'
    when 'admin_unblock_phone'              then 'moderation'
    when 'admin_reset_password_by_phone'    then 'moderation'
    when 'admin_delete_account'             then 'delete_accounts'
    when 'admin_delete_account_and_block'   then 'delete_accounts'
    else null end;
  if v_perm is null then raise exception 'function_not_allowed'; end if;
  if not (public.is_real_admin() or public.helper_can(v_perm)) then
    raise exception 'helper_not_allowed';
  end if;

  select p.oid, p.proretset, p.prorettype::regtype::text as rettype into v_proc
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = p_fn limit 1;
  if not found then raise exception 'function_missing: %', p_fn; end if;

  select coalesce(string_agg(format('%I => %L', key, value #>> '{}'), ', '), '')
    into v_arglist from jsonb_each(coalesce(p_args, '{}'::jsonb));

  perform set_config('careerk.helper_perm', v_perm, true);   -- this transaction only
  if v_proc.rettype = 'void' then
    execute format('select public.%I(%s)', p_fn, v_arglist);
    v_result := null;
  elsif v_proc.proretset then
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I(%s) x', p_fn, v_arglist) into v_result;
  else
    execute format('select to_jsonb(public.%I(%s))', p_fn, v_arglist) into v_result;
  end if;
  perform set_config('careerk.helper_perm', '', true);

  perform log_helper(p_fn, null, null, p_args - 'new_password');
  return v_result;
end $$;
grant execute on function public.helper_exec(text, jsonb) to authenticated;

-- =============================================================
-- 6) Admin: set a helper's permissions
-- =============================================================
create or replace function public.admin_set_helper(p_pharmacist_id uuid, p_is_helper boolean, p_note text, p_permissions text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_real_admin() then raise exception 'not_admin'; end if;
  update pharmacists
     set is_helper = p_is_helper,
         helper_note = case when p_is_helper then p_note else helper_note end,
         helper_permissions = case when p_is_helper then coalesce(p_permissions, '{}') else '{}' end
   where id = p_pharmacist_id;
end $$;
grant execute on function public.admin_set_helper(uuid, boolean, text, text[]) to authenticated;

-- =============================================================
-- 7) Report: which wrapped admin functions honour is_current_user_admin()
--    (if one says false it checks managers directly and needs a follow-up fix)
-- =============================================================
select p.proname as fn,
       pg_get_functiondef(p.oid) ~ 'is_current_user_admin' as helper_ready
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'admin_issue_reset_code','admin_issue_reset_code_by_phone','admin_approve_password_reset','admin_reject_password_reset',
  'admin_block_phone','admin_unblock_phone','admin_reset_password_by_phone','admin_delete_account','admin_delete_account_and_block')
union all
select 'career-v74-helper-permissions-ready', true
order by 1;
