-- CareerK — CV data columns for pharmacists
-- Adds columns to store the CV builder output on each pharmacist's profile,
-- plus a visibility flag so the user can show/hide it from other viewers.
--
-- Run ONCE in Supabase SQL Editor.

alter table public.pharmacists
  add column if not exists cv_data jsonb,
  add column if not exists cv_visible boolean not null default false,
  add column if not exists cv_updated_at timestamptz;

-- Fast lookup of pharmacists who chose to show their CV
create index if not exists idx_pharmacists_cv_visible
  on public.pharmacists (updated_at desc)
  where cv_visible = true and cv_data is not null;

select 'career-cv-columns-ready' as status;
