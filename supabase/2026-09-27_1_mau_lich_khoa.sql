-- ============================================================================
-- MÀU LỊCH CỦA TỪNG KHOÁ
--
-- Trang quản trị → Lịch tập tô mỗi khoá (và mỗi gói cộng đồng) một màu để
-- lịch tuần dễ nhìn, nhất là với giảng viên và học viên lớn tuổi. Màu do
-- studio chọn trong "Lịch từng khoá"; để trống thì trang tự chia màu theo
-- thứ tự khoá.
--
-- Chỉ nhận mã màu dạng #RRGGBB. Quyền ghi đi theo chính sách sẵn có của hai
-- bảng (chỉ quản trị sửa được), không cần thêm chính sách mới.
-- ============================================================================

alter table public.courses
  add column if not exists cal_color text;
alter table public.courses drop constraint if exists courses_cal_color_hex;
alter table public.courses add constraint courses_cal_color_hex
  check (cal_color is null or cal_color ~ '^#[0-9A-Fa-f]{6}$');
comment on column public.courses.cal_color is
  'Màu của khoá trên lịch tập (#RRGGBB). Trống = trang quản trị tự chia màu.';

alter table public.memberships
  add column if not exists cal_color text;
alter table public.memberships drop constraint if exists memberships_cal_color_hex;
alter table public.memberships add constraint memberships_cal_color_hex
  check (cal_color is null or cal_color ~ '^#[0-9A-Fa-f]{6}$');
comment on column public.memberships.cal_color is
  'Màu của gói trên lịch tập (#RRGGBB). Trống = trang quản trị tự chia màu.';
