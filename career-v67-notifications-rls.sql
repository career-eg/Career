-- CareerK v67 — Ensure users can mark their own notifications as read
-- This RLS policy allows each user to update the `read_at` column of their
-- own notifications so the bell badge clears properly.
--
-- Run this once in Supabase SQL editor.

-- Make sure RLS is enabled on the notifications table
alter table if exists public.notifications enable row level security;

-- Users can READ their own notifications (needed to fetch and show them in the bell panel)
drop policy if exists "users_read_own_notifications" on public.notifications;
create policy "users_read_own_notifications"
  on public.notifications
  for select
  to authenticated
  using (user_id = auth.uid());

-- Users can UPDATE their own notifications (only to mark them as read — read_at column)
drop policy if exists "users_update_own_notifications" on public.notifications;
create policy "users_update_own_notifications"
  on public.notifications
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Admins can do anything on notifications (send/delete/etc.)
drop policy if exists "admins_full_access_notifications" on public.notifications;
create policy "admins_full_access_notifications"
  on public.notifications
  for all
  to authenticated
  using (public.is_current_user_admin())
  with check (public.is_current_user_admin());

-- Note: INSERT is done via SECURITY DEFINER RPCs (e.g. from admin functions),
-- so no separate INSERT policy is needed for regular users.

select 'career-v67-notifications-rls-ready' as status;
