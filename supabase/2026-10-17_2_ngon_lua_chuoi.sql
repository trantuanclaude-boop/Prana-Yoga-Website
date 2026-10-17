-- ============================================================================
-- 2026-10-17_2 · NGỌN LỬA THEO CHUỖI
--
-- Học viên thấy chuỗi ngày tập của mình ngay cạnh ảnh đại diện ở trang chủ và
-- trong Hồ sơ: một ngọn lửa kèm số ngày liên tiếp. Chuỗi càng dài, lửa càng
-- đổi màu (cam → đỏ → vàng kim → xanh lam → tím). Studio sửa các bậc ở
-- admin.html → Chuỗi ngày tập → Luật tính & giao diện.
--
--   streak_settings.flames       mảng 1–8 bậc, mỗi bậc
--                                  { "from": số ngày liên tiếp tối thiểu (1–1000),
--                                    "vi": tên (1–40 ký tự), "en": tên tiếng Anh (0–40),
--                                    "c": ["#đáy", "#thân", "#lõi"] }
--                                Bậc thấp nhất luôn được tính từ ngày 1 (trang khách
--                                tự hiểu vậy); chuỗi 0 ngày là tàn tro xám, không có
--                                bậc riêng. Trigger xếp các bậc tăng dần theo "from".
--   streak_settings.flame_badge  tắt thì không hiện ngọn lửa cạnh ảnh đại diện và
--                                trong Hồ sơ (mục Chuỗi ngày tập vẫn còn).
--
-- Bộ mặc định dưới đây có bản sao ở PranaSkyline.FLAMES (index.html, admin.html).
-- Chỉ thêm cột và kiểm tra — chạy lại bao nhiêu lần cũng được.
-- ============================================================================

-- 1. Kiểm tra một mảng bậc lửa -------------------------------------------------
create or replace function private.streak_flames_ok(p jsonb)
returns boolean
language sql
immutable
set search_path to ''
as $function$
  /* CASE lồng nhau giữ đúng thứ tự soát: chỉ ép kiểu "from" khi đã chắc là số */
  select case
    when p is null or jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) not between 1 and 8 then false
    when exists (
      select 1 from jsonb_array_elements(p) e
      where case
        when jsonb_typeof(e) <> 'object' then true
        when coalesce(e->>'from', '') !~ '^[0-9]{1,4}$' then true
        when (e->>'from')::int not between 1 and 1000 then true
        when jsonb_typeof(e->'vi') is distinct from 'string' then true
        when char_length(btrim(e->>'vi')) not between 1 and 40 then true
        when e ? 'en' and jsonb_typeof(e->'en') <> 'string' then true
        when char_length(coalesce(e->>'en', '')) > 40 then true
        when jsonb_typeof(e->'c') is distinct from 'array' then true
        when jsonb_array_length(e->'c') <> 3 then true
        else exists (
          select 1 from jsonb_array_elements(e->'c') x
          where jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ '^#[0-9A-Fa-f]{6}$'
        )
      end
    ) then false
    else (select count(distinct (e->>'from')::int) from jsonb_array_elements(p) e) = jsonb_array_length(p)
  end
$function$;
comment on function private.streak_flames_ok(jsonb) is
  'Mảng bậc lửa hợp lệ: 1–8 bậc, from 1–1000 không trùng, tên vi 1–40 ký tự, en ≤ 40, ba màu #rrggbb.';

-- 2. Hai cột mới ----------------------------------------------------------------
alter table public.streak_settings
  add column if not exists flames jsonb not null default
    '[{"from":1,"vi":"Lửa cam","en":"Orange flame","c":["#d9481f","#f08a2c","#ffd27a"]},
      {"from":7,"vi":"Lửa đỏ","en":"Red flame","c":["#a50f2d","#e8322b","#ff9e6b"]},
      {"from":21,"vi":"Lửa vàng kim","en":"Golden flame","c":["#b86a00","#f2b01e","#fff3b0"]},
      {"from":49,"vi":"Lửa xanh lam","en":"Blue flame","c":["#123fbf","#2e8bff","#b5ecff"]},
      {"from":108,"vi":"Lửa tím","en":"Violet flame","c":["#4e1aa8","#9a4dff","#f3d2ff"]}]'::jsonb,
  add column if not exists flame_badge boolean not null default true;

alter table public.streak_settings drop constraint if exists streak_settings_flames_ok;
alter table public.streak_settings
  add constraint streak_settings_flames_ok check (private.streak_flames_ok(flames));

comment on column public.streak_settings.flames is
  'Bậc lửa theo chuỗi ngày liên tiếp: [{from, vi, en, c:[đáy, thân, lõi]}], xếp tăng dần. Sửa ở admin.html → Chuỗi ngày tập.';
comment on column public.streak_settings.flame_badge is
  'Hiện ngọn lửa chuỗi ngày tập cạnh ảnh đại diện (trang chủ) và trong Hồ sơ.';

-- Quản trị sửa được hai cột mới (quyền sửa theo cột, như các cột cũ)
grant update (flames, flame_badge) on public.streak_settings to authenticated;

-- 3. Trigger: thêm bước xếp bậc lửa ------------------------------------------------
-- security definer: thân hàm gọi private.streak_flames_ok theo tên, mà người sửa
-- (vai authenticated) không chắc có quyền dùng lược đồ private. Hàm chỉ đóng dấu
-- giờ / người sửa và xếp lại mảng, không đọc hay ghi bảng nào khác.
create or replace function private.streak_settings_stamp()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  /* Mốc: bỏ trùng, xếp tăng dần — trang khách đọc thẳng mảng này */
  new.milestones := (select array_agg(distinct m order by m) from unnest(new.milestones) m);
  new.rest_days := coalesce((select array_agg(distinct d order by d) from unnest(new.rest_days) d), '{}');
  /* Bậc lửa: xếp tăng dần theo số ngày. Mảng hỏng thì để nguyên cho ràng buộc
     streak_settings_flames_ok báo lỗi rõ ràng. */
  if private.streak_flames_ok(new.flames) then
    new.flames := (select jsonb_agg(e order by (e->>'from')::int) from jsonb_array_elements(new.flames) e);
  end if;
  return new;
end
$function$;
