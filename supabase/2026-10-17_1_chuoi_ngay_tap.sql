-- ============================================================================
-- 2026-10-17_1 · CHUỖI NGÀY TẬP (streak)
--
-- Học viên thấy hôm nay mình đã tập bao nhiêu, đã giữ chuỗi bao nhiêu ngày
-- liên tiếp, và cả năm tập thành một "thành phố khối" (Lớp của tôi → Chuỗi
-- ngày tập). Studio chỉnh luật tính và sửa từng ngày của từng học viên ở
-- admin.html → Chuỗi ngày tập.
--
--   public.streak_settings  một dòng duy nhất: luật tính một "ngày tập", ngày
--                           nghỉ không làm đứt chuỗi, các mốc, bảng màu…
--                           Ai cũng đọc được (trang khách cần), chỉ quản trị sửa.
--   public.study_days       mỗi học viên một dòng mỗi ngày có tập:
--                           giây học online, các bài đã xong trong ngày,
--                           phút tự tập (học viên tự khai), phút ở studio
--                           (studio điểm danh) và một dòng ghi chú của studio.
--                           Học viên chỉ đọc dòng của mình; ghi qua hàm.
--
-- Hàm:
--   study_ping(course, idx, sec, done)  phòng học gửi lên mỗi phút đang học,
--                                       và khi một bài xong. Ngày do máy chủ
--                                       tính theo giờ Việt Nam — trang không
--                                       tự chọn được ngày.
--   study_self(minutes)                 "Tôi đã tự tập hôm nay" — chỉ hôm nay,
--                                       và chỉ khi studio cho phép.
--   admin_study_set(user, day, self, studio, note)   studio sửa một ngày.
--   admin_study_overview(q, limit)      danh sách học viên kèm chuỗi hiện tại,
--                                       chuỗi dài nhất, số ngày tập 30 ngày qua.
--
-- Một "ngày tập": học xong ít nhất một bài, hoặc có buổi ở studio, hoặc tổng
-- phút (online + tự tập + studio) đạt goal_minutes. Ngày chưa đạt mà rơi vào
-- rest_days (1 = thứ Hai … 7 = Chủ nhật) thì chuỗi không đứt, chỉ không cộng.
-- Hôm nay chưa đạt cũng không làm đứt chuỗi — ngày chưa hết.
-- Luật này có bản sao trong JS (computeStats của PranaSkyline ở index.html và
-- admin.html) — đổi một chỗ thì đổi cả ba.
-- ============================================================================

-- 1. Cài đặt ------------------------------------------------------------------
create table if not exists public.streak_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default true,
  goal_minutes smallint not null default 10 check (goal_minutes between 1 and 240),
  rest_days smallint[] not null default '{}'
    check (rest_days <@ array[1,2,3,4,5,6,7]::smallint[] and cardinality(rest_days) <= 6),
  milestones smallint[] not null default '{3,7,21,49,108}'
    check (cardinality(milestones) between 1 and 8 and 0 < all (milestones) and 1000 >= all (milestones)),
  allow_self boolean not null default true,
  studio_minutes smallint not null default 60 check (studio_minutes between 5 and 300),
  palette text not null default 'sage'
    check (palette in ('sage','gold','lotus','ocean','ember','grape','github','mono')),
  default_view text not null default '3d' check (default_view in ('2d','3d')),
  height_scale numeric(3,2) not null default 1 check (height_scale between 0.5 and 1.8),
  note text not null default '' check (char_length(note) <= 280),
  note_en text not null default '' check (char_length(note_en) <= 280),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
comment on table public.streak_settings is
  'Một dòng (id = 1): luật tính chuỗi ngày tập và cách trang khách vẽ nó. Sửa ở admin.html → Chuỗi ngày tập.';

insert into public.streak_settings (id) values (1) on conflict (id) do nothing;

alter table public.streak_settings enable row level security;
revoke all on public.streak_settings from anon, authenticated;
grant select on public.streak_settings to anon, authenticated;
grant update (enabled, goal_minutes, rest_days, milestones, allow_self, studio_minutes,
              palette, default_view, height_scale, note, note_en)
  on public.streak_settings to authenticated;

drop policy if exists "Ai cũng đọc luật chuỗi ngày tập" on public.streak_settings;
create policy "Ai cũng đọc luật chuỗi ngày tập" on public.streak_settings
  for select to anon, authenticated using (true);
drop policy if exists "Quản trị sửa luật chuỗi ngày tập" on public.streak_settings;
create policy "Quản trị sửa luật chuỗi ngày tập" on public.streak_settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function private.streak_settings_stamp()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  /* Mốc: bỏ trùng, xếp tăng dần — trang khách đọc thẳng mảng này */
  new.milestones := (select array_agg(distinct m order by m) from unnest(new.milestones) m);
  new.rest_days := coalesce((select array_agg(distinct d order by d) from unnest(new.rest_days) d), '{}');
  return new;
end
$function$;
drop trigger if exists streak_settings_stamp on public.streak_settings;
create trigger streak_settings_stamp before update on public.streak_settings
  for each row execute function private.streak_settings_stamp();

-- 2. Ngày tập -------------------------------------------------------------------
create table if not exists public.study_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  online_sec integer not null default 0 check (online_sec between 0 and 43200),
  lessons text[] not null default '{}' check (cardinality(lessons) <= 60),
  self_min smallint not null default 0 check (self_min between 0 and 240),
  studio_min smallint not null default 0 check (studio_min between 0 and 600),
  staff_note text not null default '' check (char_length(staff_note) <= 200),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);
comment on table public.study_days is
  'Mỗi học viên một dòng mỗi ngày có tập (giờ Việt Nam). lessons = các "khoá:idx" xong trong ngày. Ghi qua study_ping / study_self / admin_study_set.';
create index if not exists study_days_day_idx on public.study_days (day);

alter table public.study_days enable row level security;
revoke all on public.study_days from anon, authenticated;
grant select on public.study_days to authenticated;

drop policy if exists "Học viên xem ngày tập của mình" on public.study_days;
create policy "Học viên xem ngày tập của mình" on public.study_days
  for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());

-- Ngày hôm nay theo giờ Việt Nam: mọi hàm ghi đều lấy ngày từ đây
create or replace function private.vn_today()
returns date
language sql
stable
set search_path to ''
as $function$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $function$;

-- Dòng không còn gì thì xoá, để bảng chỉ giữ những ngày thật sự có tập
create or replace function private.study_trim(p_user uuid, p_day date)
returns void
language sql
set search_path to ''
as $function$
  delete from public.study_days s
  where s.user_id = p_user and s.day = p_day
    and s.online_sec = 0 and cardinality(s.lessons) = 0
    and s.self_min = 0 and s.studio_min = 0 and s.staff_note = ''
$function$;

create or replace function private.study_json(p_user uuid, p_day date)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  select coalesce(
    (select to_jsonb(s) - 'user_id' from public.study_days s where s.user_id = p_user and s.day = p_day),
    jsonb_build_object('day', p_day, 'online_sec', 0, 'lessons', '[]'::jsonb,
                       'self_min', 0, 'studio_min', 0, 'staff_note', ''))
$function$;

-- 3. Phòng học gửi lên ---------------------------------------------------------
create or replace function public.study_ping(p_course text, p_idx smallint, p_sec integer, p_done boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_day date := private.vn_today();
  /* Trang gửi mỗi phút một lần; 180 giây là trần rộng rãi cho một lần gửi trễ */
  v_sec integer := least(greatest(coalesce(p_sec, 0), 0), 180);
  v_key text := p_course || ':' || p_idx;
  v_done boolean := coalesce(p_done, false);
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_course is null or p_idx is null or not public.can_open_lesson(p_course, p_idx) then
    raise exception 'lesson_locked';
  end if;
  if v_sec = 0 and not v_done then return private.study_json(v_uid, v_day); end if;

  insert into public.study_days as s (user_id, day, online_sec, lessons)
  values (v_uid, v_day, v_sec, case when v_done then array[v_key] else '{}'::text[] end)
  on conflict (user_id, day) do update set
    online_sec = least(s.online_sec + excluded.online_sec, 43200),
    lessons = case
      when v_done and not (v_key = any (s.lessons)) and cardinality(s.lessons) < 60 then s.lessons || v_key
      else s.lessons end,
    updated_at = now();
  return private.study_json(v_uid, v_day);
end
$function$;
revoke all on function public.study_ping(text, smallint, integer, boolean) from public, anon;
grant execute on function public.study_ping(text, smallint, integer, boolean) to authenticated;

-- 4. "Tôi đã tự tập hôm nay" ----------------------------------------------------
create or replace function public.study_self(p_minutes integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_day date := private.vn_today();
  v_min integer := least(greatest(coalesce(p_minutes, 0), 0), 240);
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not coalesce((select allow_self from public.streak_settings where id = 1), false) then
    raise exception 'self_off';
  end if;
  insert into public.study_days as s (user_id, day, self_min)
  values (v_uid, v_day, v_min)
  on conflict (user_id, day) do update set self_min = excluded.self_min, updated_at = now();
  perform private.study_trim(v_uid, v_day);
  return private.study_json(v_uid, v_day);
end
$function$;
revoke all on function public.study_self(integer) from public, anon;
grant execute on function public.study_self(integer) to authenticated;

-- 5. Studio sửa một ngày ---------------------------------------------------------
create or replace function public.admin_study_set(
  p_user uuid, p_day date, p_self_min integer, p_studio_min integer, p_note text default '')
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_today date := private.vn_today();
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_day is null or p_day > v_today or p_day < v_today - 400 then raise exception 'day_invalid'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user) then raise exception 'user_not_found'; end if;

  insert into public.study_days as s (user_id, day, self_min, studio_min, staff_note)
  values (p_user, p_day,
          least(greatest(coalesce(p_self_min, 0), 0), 240),
          least(greatest(coalesce(p_studio_min, 0), 0), 600),
          left(trim(coalesce(p_note, '')), 200))
  on conflict (user_id, day) do update set
    self_min = excluded.self_min,
    studio_min = excluded.studio_min,
    staff_note = excluded.staff_note,
    updated_at = now();
  perform private.study_trim(p_user, p_day);
  return private.study_json(p_user, p_day);
end
$function$;
revoke all on function public.admin_study_set(uuid, date, integer, integer, text) from public, anon;
grant execute on function public.admin_study_set(uuid, date, integer, integer, text) to authenticated;

-- 6. Tóm tắt chuỗi của một người ---------------------------------------------------
-- Đi xuôi 401 ngày gần nhất, đúng luật ở đầu tệp.
create or replace function private.study_summary(p_user uuid)
returns table(last_day date, today_min integer, cur_streak integer, best_streak integer,
              days_30 integer, min_30 integer, days_year integer)
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_today date := private.vn_today();
  v_goal integer;
  v_rest smallint[];
  v_run integer := 0;
  r record;
begin
  select st.goal_minutes, st.rest_days into v_goal, v_rest from public.streak_settings st where st.id = 1;
  v_goal := coalesce(v_goal, 10);
  v_rest := coalesce(v_rest, '{}');
  last_day := null; today_min := 0; best_streak := 0; days_30 := 0; min_30 := 0; days_year := 0;
  for r in
    select g.d::date as day,
           s.user_id is not null as has,
           coalesce(s.online_sec / 60 + s.self_min + s.studio_min, 0) as mins,
           coalesce(cardinality(s.lessons) > 0 or s.studio_min > 0
                    or s.online_sec / 60 + s.self_min + s.studio_min >= v_goal, false) as ok
    from generate_series(v_today - 400, v_today, interval '1 day') as g(d)
    left join public.study_days s on s.user_id = p_user and s.day = g.d::date
    order by 1
  loop
    if r.ok then
      v_run := v_run + 1;
      if v_run > best_streak then best_streak := v_run; end if;
      if r.day > v_today - 365 then days_year := days_year + 1; end if;
      if r.day > v_today - 30 then days_30 := days_30 + 1; end if;
    elsif r.day < v_today and not (extract(isodow from r.day)::smallint = any (v_rest)) then
      v_run := 0;
    end if;
    if r.has then
      last_day := r.day;
      if r.day > v_today - 30 then min_30 := min_30 + r.mins; end if;
    end if;
    if r.day = v_today then today_min := r.mins; end if;
  end loop;
  cur_streak := v_run;
  return next;
end
$function$;
revoke all on function private.study_summary(uuid) from public, anon, authenticated;

-- 7. Danh sách cho trang quản trị ---------------------------------------------------
-- Ô tìm trống: chỉ những người có tập trong 400 ngày qua. Có chữ: mọi tài
-- khoản khớp email / tên / số điện thoại, để quầy tìm được người chưa tập
-- lần nào mà điểm danh buổi đầu.
create or replace function public.admin_study_overview(p_q text default '', p_limit integer default 200)
returns table(
  user_id uuid, email text, full_name text, phone text, is_staff boolean,
  last_day date, today_min integer, cur_streak integer, best_streak integer,
  days_30 integer, min_30 integer, days_year integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  with who as (
    select u.id, u.email::text as email, coalesce(p.full_name, '') as full_name,
           coalesce(p.phone, '') as phone, u.created_at,
           exists (select 1 from public.staff st where st.user_id = u.id) as is_staff
    from auth.users u
    left join public.profiles p on p.id = u.id
    where public.is_admin()
      and case
        when nullif(trim(coalesce(p_q, '')), '') is null then exists (
          select 1 from public.study_days s
          where s.user_id = u.id and s.day >= private.vn_today() - 400)
        else u.email ilike '%' || trim(p_q) || '%'
          or coalesce(p.full_name, '') ilike '%' || trim(p_q) || '%'
          or coalesce(p.phone, '') ilike '%' || trim(p_q) || '%'
      end
    order by u.created_at desc
    limit 500
  )
  select w.id, w.email, w.full_name, w.phone, w.is_staff,
         x.last_day, x.today_min, x.cur_streak, x.best_streak, x.days_30, x.min_30, x.days_year
  from who w
  cross join lateral private.study_summary(w.id) x
  order by x.cur_streak desc, x.last_day desc nulls last, w.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 500)
$function$;
revoke all on function public.admin_study_overview(text, integer) from public, anon;
grant execute on function public.admin_study_overview(text, integer) to authenticated;
