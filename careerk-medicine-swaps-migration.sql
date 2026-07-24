-- ============================================================
-- CareerK — Medicine Swaps (نير إكسباير وتبادل)
-- Governorate-scoped marketplace for near-expiry medicine + buy requests.
-- Run once in Supabase SQL Editor. Safe to re-run.
-- ============================================================

create table if not exists public.medicine_swaps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  pharmacist_id uuid references public.pharmacists(id) on delete cascade,

  -- 'sell' = عرض نير إكسباير للبيع | 'buy' = طلب شراء دواء
  post_type text not null check (post_type in ('sell','buy')),

  medicine_name text not null,
  quantity integer,
  quantity_unit text default 'علبة',  -- علبة, شريط, أمبولة, زجاجة, كيس

  -- For sell posts
  expiry_date date,
  discount_percent integer check (discount_percent >= 0 and discount_percent <= 100),
  has_invoice boolean,

  -- For buy posts — how urgent
  urgency text check (urgency in ('normal','urgent','super_urgent')) default 'normal',

  notes text,

  -- Governorate filter is enforced client-side + here for consistency.
  governorate text not null,
  city text,

  -- Contact denorm — cached from pharmacist for one-shot render.
  whatsapp text,
  poster_name text,

  -- Status
  is_active boolean not null default true,
  is_rejected boolean not null default false,
  rejection_reason text,

  -- Timestamps
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  -- Posts auto-expire after 7 days. Cron / admin can prune later.
  expires_at timestamptz default (now() + interval '7 days')
);

-- Speeds up the primary "browse by governorate" query.
create index if not exists idx_medicine_swaps_gov_active
  on public.medicine_swaps(governorate, created_at desc)
  where is_active = true and is_rejected = false;

-- Speeds up "my listings" query.
create index if not exists idx_medicine_swaps_user
  on public.medicine_swaps(user_id, created_at desc);

-- ============ RLS ============
alter table public.medicine_swaps enable row level security;

-- Everyone (including anon) can read active + non-rejected posts. This lets
-- Google index them and lets visitors browse before signing up.
drop policy if exists "swaps_read_active" on public.medicine_swaps;
create policy "swaps_read_active" on public.medicine_swaps
  for select using (is_active = true and is_rejected = false);

-- Only verified pharmacists can insert. RLS check ties to pharmacists table.
drop policy if exists "swaps_insert_verified" on public.medicine_swaps;
create policy "swaps_insert_verified" on public.medicine_swaps
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.pharmacists p
      where p.user_id = auth.uid()
      and p.is_verified = true
    )
  );

-- Users can update/delete their own posts.
drop policy if exists "swaps_update_own" on public.medicine_swaps;
create policy "swaps_update_own" on public.medicine_swaps
  for update using (auth.uid() = user_id);

drop policy if exists "swaps_delete_own" on public.medicine_swaps;
create policy "swaps_delete_own" on public.medicine_swaps
  for delete using (auth.uid() = user_id);

-- ============================================================
-- Done. Feature ships as tab "💊 تبادل" in the main site.
-- Admin can review + reject via the admin panel.
-- ============================================================
