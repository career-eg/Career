-- CareerK v72 — Engagement pack
--   1) "مين شاف بروفايلك"  : profile_views + record_profile_view() + daily rolled-up notification
--   2) تنبيهات الوظايف       : per-pharmacist alert prefs + trigger on new jobs → notifications
--   3) شيفت بديل            : relief_shifts table + available_relief flag + trigger → notifications
--   + notifications get kind/link/ref_key columns and are added to realtime.
-- Safe to re-run (IF NOT EXISTS / OR REPLACE everywhere).

-- =============================================================
-- 0) NOTIFICATIONS — extra columns + realtime
-- =============================================================
alter table public.notifications
  add column if not exists kind    text,
  add column if not exists link    text,
  add column if not exists ref_key text;

create unique index if not exists uq_notifications_user_ref
  on public.notifications (user_id, ref_key) where ref_key is not null;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    execute 'alter publication supabase_realtime add table public.notifications';
  end if;
exception when undefined_object then null;  -- publication missing on this project: skip
end $$;

-- =============================================================
-- 1) PROFILE VIEWS
-- =============================================================
create table if not exists public.profile_views (
  id            bigserial primary key,
  pharmacist_id uuid not null references public.pharmacists(id) on delete cascade,
  viewer_key    text not null,                 -- auth uid, or 'anon:<device id>' for guests
  viewer_user_id uuid,
  viewer_kind   text not null default 'guest', -- pharmacy | pharmacist | guest
  viewer_gov    text,
  view_day      date not null default ((now() at time zone 'Africa/Cairo')::date),
  created_at    timestamptz not null default now(),
  unique (pharmacist_id, viewer_key, view_day)
);
create index if not exists idx_profile_views_ph_day on public.profile_views (pharmacist_id, view_day desc);

alter table public.profile_views enable row level security;
drop policy if exists "owner_reads_profile_views" on public.profile_views;
create policy "owner_reads_profile_views" on public.profile_views for select to authenticated
  using (pharmacist_id in (select id from public.pharmacists where user_id = auth.uid())
         or public.is_current_user_admin());
-- No insert policy: writes only go through record_profile_view() below.
grant select on public.profile_views to authenticated;  -- Supabase: new public tables need explicit grants

create or replace function public.record_profile_view(p_pharmacist_id uuid, p_device text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_owner   uuid;
  v_key     text;
  v_kind    text := 'guest';
  v_gov     text;
  v_day     date := (now() at time zone 'Africa/Cairo')::date;
  v_rows    int;
  v_count   int;
  v_ph      int;
begin
  select user_id into v_owner from pharmacists where id = p_pharmacist_id;
  if v_owner is null then return; end if;
  if v_uid is not null and v_uid = v_owner then return; end if;   -- own profile doesn't count

  if v_uid is not null then
    v_key := v_uid::text;
    select governorate into v_gov from pharmacies where user_id = v_uid limit 1;
    if found then v_kind := 'pharmacy';
    else
      select governorate into v_gov from pharmacists where user_id = v_uid limit 1;
      if found then v_kind := 'pharmacist'; end if;
    end if;
  else
    if coalesce(length(p_device),0) < 8 then return; end if;
    v_key := 'anon:' || left(p_device, 64);
  end if;

  insert into profile_views (pharmacist_id, viewer_key, viewer_user_id, viewer_kind, viewer_gov, view_day)
  values (p_pharmacist_id, v_key, v_uid, v_kind, v_gov, v_day)
  on conflict (pharmacist_id, viewer_key, view_day) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then return; end if;

  select count(*), count(*) filter (where viewer_kind = 'pharmacy')
    into v_count, v_ph
    from profile_views where pharmacist_id = p_pharmacist_id and view_day = v_day;

  -- One rolled-up notification per day, refreshed (and re-marked unread) on each new viewer.
  insert into notifications (user_id, title, body, kind, link, ref_key, created_at, read_at)
  values (v_owner,
          '👀 بروفايلك اتشاف النهارده',
          case when v_ph > 0
               then v_count || ' زيارة النهارده، منهم ' || v_ph || ' من أصحاب صيدليات. كمّل بروفايلك عشان تتطلب أكتر.'
               else v_count || ' زيارة لبروفايلك النهارده. كمّل بروفايلك عشان تبان أكتر.' end,
          'views', 'dash-pharmacist', 'views:' || v_day, now(), null)
  on conflict (user_id, ref_key) where ref_key is not null
  do update set body = excluded.body, created_at = now(), read_at = null;
end $$;
grant execute on function public.record_profile_view(uuid, text) to anon, authenticated;

create or replace function public.my_profile_view_stats()
returns jsonb language sql security definer set search_path = public stable as $$
  with me as (select id from pharmacists where user_id = auth.uid() limit 1),
       v as (select * from profile_views where pharmacist_id = (select id from me))
  select jsonb_build_object(
    'today', (select count(*) from v where view_day = (now() at time zone 'Africa/Cairo')::date),
    'week',  (select count(*) from v where view_day > (now() at time zone 'Africa/Cairo')::date - 7),
    'total', (select count(*) from v),
    'pharmacies_week', (select count(*) from v where viewer_kind = 'pharmacy' and view_day > (now() at time zone 'Africa/Cairo')::date - 7),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('kind', viewer_kind, 'gov', viewer_gov, 'at', created_at) order by created_at desc)
                        from (select * from v order by created_at desc limit 6) r), '[]'::jsonb)
  );
$$;
grant execute on function public.my_profile_view_stats() to authenticated;

-- =============================================================
-- 2) JOB ALERTS (targeted)
-- =============================================================
alter table public.pharmacists
  add column if not exists job_alerts     boolean not null default true,
  add column if not exists alert_govs     text[],      -- null/empty = own governorate
  add column if not exists alert_shifts   text[],      -- null/empty = any shift
  add column if not exists available_relief boolean not null default false;

create or replace function public.gov_ar(p text)
returns text language sql immutable as $$
  select coalesce((jsonb_build_object(
    'cairo','القاهرة','giza','الجيزة','alex','الإسكندرية','qalyubia','القليوبية','sharqia','الشرقية',
    'dakahlia','الدقهلية','beheira','البحيرة','kafr','كفر الشيخ','gharbia','الغربية','menoufia','المنوفية',
    'damietta','دمياط','portsaid','بورسعيد','ismailia','الإسماعيلية','suez','السويس','nsinai','شمال سيناء',
    'ssinai','جنوب سيناء','redsea','البحر الأحمر','matrouh','مطروح','faiyum','الفيوم','benisuef','بني سويف',
    'minya','المنيا','assiut','أسيوط','sohag','سوهاج','qena','قنا','luxor','الأقصر','aswan','أسوان',
    'newvalley','الوادي الجديد') ->> p), p, '');
$$;

create or replace function public.notify_job_alerts()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_poster  uuid;
  v_ph_name text;
  v_shift   text;
  v_where   text;
begin
  if new.is_active is not true then return new; end if;
  select user_id, name into v_poster, v_ph_name from pharmacies where id = new.pharmacy_id;
  v_shift := case new.shift_type when 'morning' then 'صباحي' when 'evening' then 'مسائي' when 'night' then 'ليلي'
                                 when 'fulltime' then 'دوام كامل' when 'rotational' then 'شيفتات' else null end;
  v_where := coalesce(nullif(new.city, '') || ' · ', '') || gov_ar(new.governorate);

  insert into notifications (user_id, title, body, kind, link, ref_key)
  select p.user_id,
         '💼 وظيفة جديدة في ' || v_where,
         coalesce(nullif(new.title, ''), 'وظيفة صيدلي') ||
           coalesce(' · ' || v_shift, '') ||
           case when new.salary_min is not null then ' · من ' || new.salary_min || ' ج' else '' end ||
           coalesce(' — ' || v_ph_name, ''),
         'job', 'job:' || new.id, 'job:' || new.id
  from pharmacists p
  where p.job_alerts
    and p.user_id is not null
    and p.user_id is distinct from v_poster
    and (case when coalesce(cardinality(p.alert_govs), 0) > 0 then new.governorate = any(p.alert_govs)
              else new.governorate = p.governorate end)
    and (coalesce(cardinality(p.alert_shifts), 0) = 0 or new.shift_type = any(p.alert_shifts))
  on conflict (user_id, ref_key) where ref_key is not null do nothing;
  return new;
end $$;

drop trigger if exists trg_notify_job_alerts on public.jobs;
create trigger trg_notify_job_alerts after insert on public.jobs
  for each row execute function public.notify_job_alerts();

-- =============================================================
-- 3) RELIEF SHIFTS (شيفت بديل)
-- =============================================================
create table if not exists public.relief_shifts (
  id             uuid primary key default gen_random_uuid(),
  poster_user_id uuid not null default auth.uid(),
  pharmacy_name  text not null,
  whatsapp       text not null,
  governorate    text not null,
  city           text,
  shift_date     date not null,
  start_time     time not null,
  end_time       time not null,
  pay            integer,
  note           text,
  status         text not null default 'open' check (status in ('open','filled','cancelled')),
  created_at     timestamptz not null default now()
);
create index if not exists idx_relief_open on public.relief_shifts (shift_date, governorate) where status = 'open';
grant select on public.relief_shifts to anon, authenticated;
grant insert, update, delete on public.relief_shifts to authenticated;

alter table public.relief_shifts enable row level security;
drop policy if exists "public_read_relief"  on public.relief_shifts;
create policy "public_read_relief"  on public.relief_shifts for select to anon, authenticated using (true);
drop policy if exists "own_insert_relief"   on public.relief_shifts;
create policy "own_insert_relief"   on public.relief_shifts for insert to authenticated with check (poster_user_id = auth.uid());
drop policy if exists "own_update_relief"   on public.relief_shifts;
create policy "own_update_relief"   on public.relief_shifts for update to authenticated
  using (poster_user_id = auth.uid() or public.is_current_user_admin())
  with check (poster_user_id = auth.uid() or public.is_current_user_admin());
drop policy if exists "own_delete_relief"   on public.relief_shifts;
create policy "own_delete_relief"   on public.relief_shifts for delete to authenticated
  using (poster_user_id = auth.uid() or public.is_current_user_admin());

create or replace function public.time_ar(t time)
returns text language sql immutable as $$
  select to_char(t, 'FMHH12') || case when to_char(t, 'MI') = '00' then '' else ':' || to_char(t, 'MI') end
         || case when extract(hour from t) < 12 then ' ص' else ' م' end;
$$;

create or replace function public.notify_relief_shift()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_when text;
begin
  v_when := case when new.shift_date = (now() at time zone 'Africa/Cairo')::date then 'النهارده'
                 when new.shift_date = (now() at time zone 'Africa/Cairo')::date + 1 then 'بكرة'
                 else to_char(new.shift_date, 'DD/MM') end
            || ' من ' || time_ar(new.start_time) || ' لـ ' || time_ar(new.end_time);
  insert into notifications (user_id, title, body, kind, link, ref_key)
  select p.user_id,
         '🚨 مطلوب صيدلي بديل ' || v_when,
         new.pharmacy_name || ' · ' || coalesce(nullif(new.city, '') || ' · ', '') || gov_ar(new.governorate) ||
           case when new.pay is not null then ' · ' || new.pay || ' ج' else '' end,
         'relief', 'relief:' || new.id, 'relief:' || new.id
  from pharmacists p
  where p.available_relief
    and p.user_id is not null
    and p.user_id <> new.poster_user_id
    and p.governorate = new.governorate
  on conflict (user_id, ref_key) where ref_key is not null do nothing;
  return new;
end $$;

drop trigger if exists trg_notify_relief_shift on public.relief_shifts;
create trigger trg_notify_relief_shift after insert on public.relief_shifts
  for each row execute function public.notify_relief_shift();

select 'career-v72-engagement-ready' as status;
