-- ============================================================================
-- MÀU LỊCH CHO HỌC VIÊN
--
-- "Lớp của tôi" (index.html) bày lịch tập giống trang quản trị: mỗi khoá một
-- màu, đúng màu studio chọn ở Quản trị → Lịch tập.
--
--   1. Chốt màu cho khoá / gói nào còn trống cal_color, theo đúng cách trang
--      quản trị đang tự chia (khoá học xếp theo sort_order, key; rồi tới gói
--      cộng đồng; lần lượt mười hai màu). Nhờ vậy hai trang luôn cùng một màu,
--      và thêm khoá mới về sau cũng không làm màu các khoá cũ nhảy chỗ.
--   2. public.my_schedule() trả thêm cột color. Đổi kiểu trả về nên phải xoá
--      hàm cũ rồi tạo lại; quyền gọi đặt lại y như 2026-09-25_5.
--
-- Cần: 2026-09-25_5_lich_tap.sql, 2026-09-27_1_mau_lich_khoa.sql.
-- ============================================================================

-- 1. Chốt màu còn trống ------------------------------------------------------
with pal as (
  select array['#2E7D4F','#1F5FAD','#C0392B','#B35300','#6D3FB0','#B8336A',
               '#0E7C86','#7A5230','#8A6D00','#2C3E80','#5B6E1C','#4A5560'] as c
), c_order as (
  select key, row_number() over (order by sort_order, key) - 1 as i from public.courses
), m_order as (
  select key, (select count(*) from public.courses) + row_number() over (order by sort_order, key) - 1 as i
  from public.memberships
), c_upd as (
  update public.courses t set cal_color = pal.c[(o.i % 12) + 1]
  from c_order o, pal
  where t.key = o.key and t.cal_color is null
  returning t.key
)
update public.memberships t set cal_color = pal.c[(o.i % 12) + 1]
from m_order o, pal
where t.key = o.key and t.cal_color is null;

-- 2. Hàm cho học viên, thêm cột color ----------------------------------------
drop function if exists public.my_schedule();
create function public.my_schedule()
returns table (
  id uuid, kind text, item_key text,
  title text, title_en text, days smallint[], starts_at time, ends_at time,
  place text, place_en text, teacher text, note text, note_en text,
  start_date date, end_date date, color text
)
language sql
stable
security definer
set search_path to ''
as $function$
  select s.id,
         case when s.course_key is not null then 'course' else 'membership' end,
         coalesce(s.course_key, s.membership_key),
         s.title, s.title_en, s.days, s.starts_at, s.ends_at,
         s.place, s.place_en, s.teacher, s.note, s.note_en,
         s.start_date, s.end_date,
         coalesce(c.cal_color, m.cal_color)
  from public.class_schedule s
  left join public.courses c on c.key = s.course_key
  left join public.memberships m on m.key = s.membership_key
  where auth.uid() is not null
    and s.is_active
    and (s.end_date is null or s.end_date >= (now() at time zone 'Asia/Ho_Chi_Minh')::date)
    and (
      (s.course_key is not null and exists (
        select 1 from private.entitlements(auth.uid()) e
        where e.course_key = s.course_key and e.full_access))
      or
      (s.membership_key is not null and exists (
        select 1 from private.active_memberships(auth.uid()) a
        where a.membership_key = s.membership_key))
    )
  order by s.starts_at, s.sort_order, s.created_at
$function$;
comment on function public.my_schedule() is
  'Ca tập của những khoá người đang đăng nhập học trọn và những gói còn hạn của họ, kèm màu của khoá.';
revoke all on function public.my_schedule() from public, anon;
grant execute on function public.my_schedule() to authenticated;
