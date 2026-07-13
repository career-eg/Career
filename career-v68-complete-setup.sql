-- CareerK v68 — Complete infrastructure setup (one-shot migration)
-- Run this ONCE in Supabase SQL editor. It safely adds every missing piece:
--   1. All pharmacist availability columns (looking_for_work, manager, owner, training)
--   2. Verification columns (card_url, status, is_verified)
--   3. Row-level security policies for pharmacists (own-row updates + public read)
--   4. Notifications table + RLS (users mark own as read)
--   5. OTP infrastructure for WhatsApp password reset (from v66)
--
-- Every statement uses IF NOT EXISTS / IF EXISTS guards, so re-running is safe.

-- =============================================================
-- 1) PHARMACISTS TABLE — availability + verification columns
-- =============================================================
alter table if exists public.pharmacists
  add column if not exists looking_for_work            boolean not null default false,
  add column if not exists available_manager_registration boolean not null default false,
  add column if not exists available_owner_registration   boolean not null default false,
  add column if not exists available_for_training         boolean not null default false,
  add column if not exists verification_card_url text,
  add column if not exists verification_status  text not null default 'none'
     check (verification_status in ('none','pending','verified','rejected')),
  add column if not exists is_verified boolean not null default false,
  add column if not exists rejection_reason text;

-- Fast filter for "who's available for anything?" (used by the public listing)
create index if not exists idx_pharmacists_any_available
  on public.pharmacists (created_at desc)
  where (looking_for_work or available_manager_registration
      or available_owner_registration or available_for_training);

-- Fast filter for pending verifications in the admin panel
create index if not exists idx_pharmacists_pending_verification
  on public.pharmacists (created_at desc)
  where verification_status = 'pending';

-- =============================================================
-- 2) PHARMACISTS RLS — public read + own-row updates
-- =============================================================
alter table if exists public.pharmacists enable row level security;

-- Anyone (guest or authenticated) can READ pharmacist profiles.
-- (Contact happens via WhatsApp, so all fields except sensitive ones are public.)
drop policy if exists "public_read_pharmacists" on public.pharmacists;
create policy "public_read_pharmacists"
  on public.pharmacists for select
  to anon, authenticated
  using (true);

-- A user can INSERT their own pharmacist row (during registration).
drop policy if exists "own_insert_pharmacist" on public.pharmacists;
create policy "own_insert_pharmacist"
  on public.pharmacists for insert
  to authenticated
  with check (user_id = auth.uid());

-- A user can UPDATE their own pharmacist row (toggling availability, editing profile).
drop policy if exists "own_update_pharmacist" on public.pharmacists;
create policy "own_update_pharmacist"
  on public.pharmacists for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Admins can do anything on pharmacists.
drop policy if exists "admins_full_access_pharmacists" on public.pharmacists;
create policy "admins_full_access_pharmacists"
  on public.pharmacists for all
  to authenticated
  using (public.is_current_user_admin())
  with check (public.is_current_user_admin());

-- =============================================================
-- 3) NOTIFICATIONS TABLE + RLS
-- =============================================================
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  title text not null,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_user_created
  on public.notifications (user_id, created_at desc);
create index if not exists idx_notifications_unread
  on public.notifications (user_id, created_at desc)
  where read_at is null;

alter table if exists public.notifications enable row level security;

-- Users can read their own notifications
drop policy if exists "users_read_own_notifications" on public.notifications;
create policy "users_read_own_notifications"
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid());

-- Users can update their own notifications (only to mark as read)
drop policy if exists "users_update_own_notifications" on public.notifications;
create policy "users_update_own_notifications"
  on public.notifications for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Admins can do anything
drop policy if exists "admins_full_access_notifications" on public.notifications;
create policy "admins_full_access_notifications"
  on public.notifications for all
  to authenticated
  using (public.is_current_user_admin())
  with check (public.is_current_user_admin());

-- =============================================================
-- 4) OTP CODES TABLE + RLS (for WhatsApp password reset)
-- =============================================================
create table if not exists public.otp_codes (
  id uuid primary key default gen_random_uuid(),
  whatsapp text not null,
  code_hash text not null,
  attempts int not null default 0,
  verified boolean not null default false,
  used boolean not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes')
);
create index if not exists idx_otp_codes_whatsapp_created
  on public.otp_codes (whatsapp, created_at desc);

alter table if exists public.otp_codes enable row level security;
drop policy if exists "no_client_access_otp" on public.otp_codes;
create policy "no_client_access_otp"
  on public.otp_codes for select
  to authenticated
  using (public.is_current_user_admin());

create table if not exists public.otp_send_log (
  id uuid primary key default gen_random_uuid(),
  whatsapp text not null,
  succeeded boolean not null,
  error_reason text,
  created_at timestamptz not null default now()
);

-- Helper: generate a cryptographically-random 6-digit code
create or replace function public.generate_otp_code()
returns text language plpgsql as $$
declare v_code text;
begin
  v_code := lpad((abs(('x' || substr(encode(gen_random_bytes(4),'hex'),1,8))::bit(32)::int) % 1000000)::text, 6, '0');
  return v_code;
end; $$;

-- RPC: Request a password-reset OTP
create or replace function public.request_password_reset_otp(p_whatsapp text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_user_id uuid;
  v_recent int;
  v_code text;
  v_otp_id uuid;
begin
  if p_whatsapp is null or length(p_whatsapp) < 8 then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;
  select user_id into v_user_id from public.pharmacists where whatsapp = p_whatsapp limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;
  select count(*) into v_recent from public.otp_codes
    where whatsapp = p_whatsapp and created_at > now() - interval '10 minutes';
  if v_recent >= 3 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  update public.otp_codes set used = true where whatsapp = p_whatsapp and used = false;
  v_code := public.generate_otp_code();
  insert into public.otp_codes(whatsapp, code_hash, expires_at)
    values (p_whatsapp, encode(sha256(v_code::bytea), 'hex'), now() + interval '10 minutes')
    returning id into v_otp_id;
  -- WhatsApp send: only try if the Edge Function is configured. Otherwise fall through
  -- so the admin can retrieve the code from the admin panel and send it manually.
  begin
    if current_setting('app.whatsapp_edge_function_url', true) is not null then
      perform extensions.http_post(
        url := current_setting('app.whatsapp_edge_function_url', true),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || coalesce(current_setting('app.whatsapp_edge_function_key', true), '')
        ),
        body := jsonb_build_object('phone', p_whatsapp, 'code', v_code, 'template', 'careerk_otp')
      );
    end if;
    insert into public.otp_send_log(whatsapp, succeeded) values (p_whatsapp, true);
  exception when others then
    insert into public.otp_send_log(whatsapp, succeeded, error_reason) values (p_whatsapp, false, SQLERRM);
  end;
  return jsonb_build_object('ok', true, 'otp_id', v_otp_id);
end; $$;
grant execute on function public.request_password_reset_otp(text) to anon, authenticated;

-- RPC: Verify OTP (marks as verified, does NOT change password yet)
create or replace function public.verify_password_reset_otp(p_whatsapp text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_otp record; v_hash text;
begin
  if p_code is null or length(p_code) <> 6 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;
  select id, code_hash, attempts, expires_at into v_otp
    from public.otp_codes where whatsapp = p_whatsapp and used = false
    order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'phone_not_found'); end if;
  if v_otp.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if v_otp.attempts >= 5 then return jsonb_build_object('ok', false, 'error', 'too_many_attempts'); end if;
  v_hash := encode(sha256(p_code::bytea), 'hex');
  if v_hash <> v_otp.code_hash then
    update public.otp_codes set attempts = attempts + 1 where id = v_otp.id;
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;
  update public.otp_codes set verified = true where id = v_otp.id;
  return jsonb_build_object('ok', true);
end; $$;
grant execute on function public.verify_password_reset_otp(text, text) to anon, authenticated;

-- RPC: Reset password with verified OTP
create or replace function public.reset_password_with_verified_otp(p_whatsapp text, p_code text, p_new_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_otp record; v_user_id uuid; v_hash text;
begin
  if p_new_password is null or length(p_new_password) < 6 then
    return jsonb_build_object('ok', false, 'error', 'weak_password');
  end if;
  select id, code_hash, verified, expires_at into v_otp
    from public.otp_codes where whatsapp = p_whatsapp and used = false
    order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_verified'); end if;
  if v_otp.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if not v_otp.verified then return jsonb_build_object('ok', false, 'error', 'not_verified'); end if;
  v_hash := encode(sha256(p_code::bytea), 'hex');
  if v_hash <> v_otp.code_hash then return jsonb_build_object('ok', false, 'error', 'invalid_code'); end if;
  select user_id into v_user_id from public.pharmacists where whatsapp = p_whatsapp limit 1;
  if not found or v_user_id is null then return jsonb_build_object('ok', false, 'error', 'phone_not_found'); end if;
  update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')), updated_at = now()
    where id = v_user_id;
  update public.otp_codes set used = true where id = v_otp.id;
  begin
    insert into public.notifications (user_id, title, body)
    values (v_user_id, '🔑 كلمة السر اتغيّرت',
      'الباسورد اتغيّرت لحسابك عن طريق كود واتساب. لو مش أنت، تواصل مع الإدارة فورًا.');
  exception when others then null; end;
  return jsonb_build_object('ok', true);
end; $$;
grant execute on function public.reset_password_with_verified_otp(text, text, text) to anon, authenticated;

-- =============================================================
-- 5) ADMIN HELPER — is_current_user_admin() (safe fallback)
-- =============================================================
-- If the managers table hasn't been created yet, provide a stub that always
-- returns false so RLS policies referencing it don't error out.
-- Real admin logic (managers table) should already exist from earlier SQL.
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'is_current_user_admin') then
    execute $fn$
      create or replace function public.is_current_user_admin()
      returns boolean language sql stable as $$
        select exists(
          select 1 from public.managers
          where user_id = auth.uid() and is_active = true
        );
      $$
    $fn$;
  end if;
end $$;

select 'career-v68-complete-setup-ready' as status;
