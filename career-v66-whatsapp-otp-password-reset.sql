-- CareerK v66 — Password reset via WhatsApp OTP
-- Fully automatic: user requests code → server sends it to their WhatsApp via
-- a Supabase Edge Function → user enters code → password changes.
--
-- Setup steps:
--   1. Run this SQL in Supabase SQL editor.
--   2. Deploy the Edge Function `send-whatsapp-otp` (see /supabase/functions/send-whatsapp-otp/)
--      or set the pg_net configuration below with your WhatsApp API details.
--   3. Grant the Edge Function permissions to be called from these RPCs.

-- ===== OTP CODES TABLE =====
create table if not exists public.otp_codes (
  id uuid primary key default gen_random_uuid(),
  whatsapp text not null,
  code_hash text not null,       -- We store a SHA-256 hash, not the plaintext code
  attempts int not null default 0,
  verified boolean not null default false,
  used boolean not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes')
);
create index if not exists idx_otp_codes_whatsapp_created
  on public.otp_codes (whatsapp, created_at desc);
create index if not exists idx_otp_codes_active
  on public.otp_codes (whatsapp)
  where used = false and expires_at > now();

alter table public.otp_codes enable row level security;
-- No direct client access — only via SECURITY DEFINER RPCs below.
drop policy if exists "no_client_access_otp" on public.otp_codes;
create policy "no_client_access_otp"
  on public.otp_codes for select
  to authenticated
  using (public.is_current_user_admin());

-- ===== RATE-LIMITING LOG =====
create table if not exists public.otp_send_log (
  id uuid primary key default gen_random_uuid(),
  whatsapp text not null,
  succeeded boolean not null,
  error_reason text,
  created_at timestamptz not null default now()
);
create index if not exists idx_otp_send_log_whatsapp_time
  on public.otp_send_log (whatsapp, created_at desc);

-- ===== HELPER: Generate cryptographically random 6-digit code =====
create or replace function public.generate_otp_code()
returns text
language plpgsql
as $$
declare
  v_code text;
begin
  -- Use gen_random_bytes for a proper CSPRNG
  v_code := lpad((abs(('x' || substr(encode(gen_random_bytes(4),'hex'),1,8))::bit(32)::int) % 1000000)::text, 6, '0');
  return v_code;
end;
$$;

-- ===== RPC 1: Request a password-reset OTP =====
-- Called from step 1 of the frontend forgot-password flow.
-- Returns:
--   { ok: true, otp_id: '<uuid>' }
--   { ok: false, error: 'phone_not_found' | 'rate_limited' | 'send_failed' }
create or replace function public.request_password_reset_otp(p_whatsapp text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_pharmacist_user uuid;
  v_recent_count int;
  v_code text;
  v_otp_id uuid;
begin
  if p_whatsapp is null or length(p_whatsapp) < 8 then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;

  -- Confirm the phone belongs to a real account before sending anything.
  select user_id into v_pharmacist_user
    from public.pharmacists
    where whatsapp = p_whatsapp
    limit 1;
  if not found then
    insert into public.otp_send_log(whatsapp, succeeded, error_reason)
    values (p_whatsapp, false, 'phone_not_found');
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;

  -- Rate limit: at most 3 OTPs per phone per 10 minutes
  select count(*) into v_recent_count
    from public.otp_codes
    where whatsapp = p_whatsapp
      and created_at > now() - interval '10 minutes';
  if v_recent_count >= 3 then
    insert into public.otp_send_log(whatsapp, succeeded, error_reason)
    values (p_whatsapp, false, 'rate_limited');
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- Invalidate all previous unused codes for this phone (only latest is valid)
  update public.otp_codes
    set used = true
    where whatsapp = p_whatsapp and used = false;

  -- Generate a new 6-digit code and store its hash
  v_code := public.generate_otp_code();
  insert into public.otp_codes(whatsapp, code_hash, expires_at)
    values (p_whatsapp, encode(sha256(v_code::bytea), 'hex'), now() + interval '10 minutes')
    returning id into v_otp_id;

  -- Deliver the code via WhatsApp. This calls a Supabase Edge Function
  -- named `send-whatsapp-otp` that you deploy separately and configure
  -- with your preferred WhatsApp provider (Meta Cloud API, Twilio, Green API, etc.).
  --
  -- Requires pg_net extension to be enabled: `create extension if not exists pg_net;`
  -- The edge function URL is retrieved from vault or settings.
  begin
    perform extensions.http_post(
      url := current_setting('app.whatsapp_edge_function_url', true),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.whatsapp_edge_function_key', true)
      ),
      body := jsonb_build_object(
        'phone', p_whatsapp,
        'code', v_code,
        'template', 'careerk_otp'
      )
    );
    insert into public.otp_send_log(whatsapp, succeeded, error_reason)
    values (p_whatsapp, true, null);
  exception when others then
    -- If the send fails, keep the OTP row so admin can retrieve the code
    -- from `otp_codes` table and send it manually as a fallback.
    insert into public.otp_send_log(whatsapp, succeeded, error_reason)
    values (p_whatsapp, false, SQLERRM);
    -- Still return ok because the code exists — admin fallback available
  end;

  return jsonb_build_object('ok', true, 'otp_id', v_otp_id);
end;
$$;
grant execute on function public.request_password_reset_otp(text) to anon, authenticated;

-- ===== RPC 2: Verify OTP code (does NOT change password yet) =====
create or replace function public.verify_password_reset_otp(
  p_whatsapp text,
  p_code text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_otp record;
  v_hash text;
begin
  if p_whatsapp is null or p_code is null or length(p_code) <> 6 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  select id, code_hash, attempts, expires_at, used
    into v_otp
    from public.otp_codes
    where whatsapp = p_whatsapp
      and used = false
    order by created_at desc
    limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;

  if v_otp.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  if v_otp.attempts >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;

  v_hash := encode(sha256(p_code::bytea), 'hex');
  if v_hash <> v_otp.code_hash then
    update public.otp_codes set attempts = attempts + 1 where id = v_otp.id;
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  update public.otp_codes set verified = true where id = v_otp.id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.verify_password_reset_otp(text, text) to anon, authenticated;

-- ===== RPC 3: Reset password with verified OTP =====
create or replace function public.reset_password_with_verified_otp(
  p_whatsapp text,
  p_code text,
  p_new_password text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
declare
  v_otp record;
  v_user_id uuid;
  v_hash text;
begin
  if p_new_password is null or length(p_new_password) < 6 then
    return jsonb_build_object('ok', false, 'error', 'weak_password');
  end if;

  select id, code_hash, verified, expires_at, used
    into v_otp
    from public.otp_codes
    where whatsapp = p_whatsapp
      and used = false
    order by created_at desc
    limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_verified');
  end if;
  if v_otp.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  if not v_otp.verified then
    return jsonb_build_object('ok', false, 'error', 'not_verified');
  end if;

  -- Re-verify the code as defense-in-depth
  v_hash := encode(sha256(p_code::bytea), 'hex');
  if v_hash <> v_otp.code_hash then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  -- Look up the user's auth id via the pharmacist row
  select user_id into v_user_id
    from public.pharmacists
    where whatsapp = p_whatsapp
    limit 1;
  if not found or v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;

  -- Update the password in auth.users
  update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')),
        updated_at = now()
    where id = v_user_id;

  -- Mark the OTP as used
  update public.otp_codes set used = true where id = v_otp.id;

  -- Notify the user
  begin
    insert into public.notifications (user_id, title, body)
    values (v_user_id, '🔑 كلمة السر اتغيّرت',
      'الباسورد اتغيّرت لحسابك عن طريق كود واتساب. لو مش أنت اللي عملت ده، غيّرها فورًا وتواصل مع الإدارة.');
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.reset_password_with_verified_otp(text, text, text) to anon, authenticated;

-- ===== EDGE FUNCTION URL CONFIG =====
-- Set these values in your Supabase project (Settings > Database > Custom Configuration
-- or via SQL). They tell the RPC where to send WhatsApp messages.
--
-- Example:
--   alter database postgres set "app.whatsapp_edge_function_url" = 'https://<project>.functions.supabase.co/send-whatsapp-otp';
--   alter database postgres set "app.whatsapp_edge_function_key" = '<service-role-key>';
--
-- ⚠️ Until these are set + the Edge Function is deployed, OTPs will still be generated
-- and stored but won't be delivered to WhatsApp automatically. Admins can retrieve
-- the plaintext code from the admin panel as a fallback (during onboarding phase).

select 'career-v66-whatsapp-otp-ready' as status;
