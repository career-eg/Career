-- CareerK — CV + Meal Plan columns for pharmacists
-- Adds the columns needed for the CV builder and the weekly meal planner.
-- Safe to re-run; every clause uses `if not exists`.

alter table public.pharmacists
  add column if not exists cv_data jsonb,
  add column if not exists cv_visible boolean not null default false,
  add column if not exists cv_updated_at timestamptz,
  add column if not exists meal_plan jsonb,
  add column if not exists meal_plan_updated_at timestamptz;

-- Fast lookup of pharmacists who chose to show their CV
create index if not exists idx_pharmacists_cv_visible
  on public.pharmacists (updated_at desc)
  where cv_visible = true and cv_data is not null;

select 'career-nutrition-columns-ready' as status;
