-- ============================================================================
-- 2026-10-18_1 · ĐỘ BÙNG CHÁY CỦA TỪNG BẬC LỬA
--
-- Mỗi bậc trong streak_settings.flames có thêm "fx": độ bùng cháy của hiệu ứng
-- quanh ngọn lửa học viên thấy (1 nhẹ nhàng · 2 rực rỡ · 3 bùng cháy — càng
-- cao càng nhiều đốm lửa bay, có vòng nhiệt, tia sáng xoay). Studio chọn ở
-- admin.html → Chuỗi ngày tập → Ngọn lửa → Giao diện.
--
-- "fx" không bắt buộc: thiếu thì trang khách tự chọn theo thứ hạng bậc
-- (1, 2, 2, 3, 3, 3…). Tệp này:
--   1. thay hàm kiểm tra để từ chối fx khác 1, 2, 3;
--   2. đổi giá trị mặc định của cột sang bộ có fx;
--   3. điền fx theo thứ hạng cho các bậc đang lưu mà chưa có.
-- Chạy lại bao nhiêu lần cũng được.
-- ============================================================================

-- 1. Hàm kiểm tra: như 2026-10-17_2, thêm điều kiện cho "fx" ---------------------
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
        when e ? 'fx' and (jsonb_typeof(e->'fx') <> 'number' or (e->>'fx') !~ '^[1-3]$') then true
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
  'Mảng bậc lửa hợp lệ: 1–8 bậc, from 1–1000 không trùng, tên vi 1–40 ký tự, en ≤ 40, fx 1–3 (không bắt buộc), ba màu #rrggbb.';

-- 2. Mặc định mới ------------------------------------------------------------------
alter table public.streak_settings alter column flames set default
  '[{"from":1,"vi":"Lửa cam","en":"Orange flame","c":["#d9481f","#f08a2c","#ffd27a"],"fx":1},
    {"from":7,"vi":"Lửa đỏ","en":"Red flame","c":["#a50f2d","#e8322b","#ff9e6b"],"fx":2},
    {"from":21,"vi":"Lửa vàng kim","en":"Golden flame","c":["#b86a00","#f2b01e","#fff3b0"],"fx":2},
    {"from":49,"vi":"Lửa xanh lam","en":"Blue flame","c":["#123fbf","#2e8bff","#b5ecff"],"fx":3},
    {"from":108,"vi":"Lửa tím","en":"Violet flame","c":["#4e1aa8","#9a4dff","#f3d2ff"],"fx":3}]'::jsonb;

-- 3. Bậc đang lưu mà chưa có fx: điền theo thứ hạng (giống fxDefault của trang) ---
update public.streak_settings s
set flames = (
  select jsonb_agg(case when e ? 'fx' then e else e || jsonb_build_object('fx', least(3, 1 + (o::int / 2))) end order by o)
  from jsonb_array_elements(s.flames) with ordinality t(e, o)
)
where s.id = 1
  and exists (select 1 from jsonb_array_elements(s.flames) e where not (e ? 'fx'));
