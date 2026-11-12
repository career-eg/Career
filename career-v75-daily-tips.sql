-- CareerK v75 — Daily tip overrides
-- The daily tips themselves live in /tips.json on the site (new ones are added automatically every week).
-- This table lets the admin (or a helper with the 'tips' permission) edit or hide the tip of any day.
-- Needs v74 (helper_can). Safe to re-run.

create table if not exists public.tip_overrides (
  tip_date   date primary key,
  title      text,
  body       text,
  category   text,
  source     text,
  url        text,
  is_hidden  boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

alter table public.tip_overrides enable row level security;
grant select on public.tip_overrides to anon, authenticated;
grant insert, update, delete on public.tip_overrides to authenticated;

drop policy if exists "public_read_tip_overrides" on public.tip_overrides;
create policy "public_read_tip_overrides" on public.tip_overrides for select to anon, authenticated using (true);

drop policy if exists "admin_manage_tip_overrides" on public.tip_overrides;
create policy "admin_manage_tip_overrides" on public.tip_overrides for all to authenticated
  using (public.is_current_user_admin() or public.helper_can('tips'))
  with check (public.is_current_user_admin() or public.helper_can('tips'));

select 'career-v75-daily-tips-ready' as status;
