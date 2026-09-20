-- ============================================================================
-- MÔ TẢ KHOÁ HỌC SỬA ĐƯỢC TỪ TRANG QUẢN TRỊ (9/2026)
--
-- Trước file này, phần mô tả dài của mỗi khoá (dải giới thiệu, dải phương
-- pháp, bốn ô "vì sao chọn", hàng bảo chứng, bảng màu và bộ ảnh) nằm cứng
-- trong index.html, nên khoá mới tạo từ trang quản trị mở ra chỉ có đúng
-- cái khung trống.
--
-- Một cột jsonb `design` gom tất cả những thứ ấy về một chỗ, để trang quản
-- trị sửa được mà không phải đụng vào mã nguồn. Để trống thì trang vẫn dùng
-- bản mô tả viết sẵn trong index.html (nếu khoá đó có), nên các khoá cũ
-- không đổi gì cả.
--
-- Hình dạng (mọi đoạn chữ là cặp { vi, en }):
--   {
--     "tier": 0,                          -- 0 = tự chọn hạng theo học phí
--     "palette": { "mid","deep","accent","fill","on","accentDark" },
--     "gallery": [ { "url": "...", "cap": {"vi","en"} } ],
--     "rank":  { "vi","en" },
--     "years": { "n": {"vi","en"}, "l": {"vi","en"} },
--     "strip": [ { "n": {"vi","en"}, "l": {"vi","en"} } ],
--     "story": { "h":…, "p":…, "feats": [ { "i","h","p" } ] },
--     "method":{ "eb":…, "h":…, "p":…, "steps": [ { "h","p" } ] },
--     "quote": { "vi","en" },
--     "why":   { "eb":…, "h":…, "p":…, "tiles": [ { "i","fill","h","p" } ] },
--     "creds": [ { "i", "t": {"vi","en"} } ]
--   }
--
-- Hạng trình bày (tier) đi theo phân khúc học phí, trang tự chọn:
--   hạng 1 dưới 5 triệu · hạng 2 từ 5 đến dưới 8 triệu ·
--   hạng 3 từ 8 đến dưới 10 triệu · hạng 4 từ 10 triệu trở lên.
-- Điền "tier" khác 0 là ép hạng, không cần biết học phí bao nhiêu.
--
-- Chạy sau 2026-09-17_1_don_hoc_vien_cu.sql.
-- ============================================================================

alter table public.courses
  add column if not exists design jsonb not null default '{}'::jsonb;

-- Chặn dán nhầm cả một tệp vào đây: bản mô tả dài nhất trong trang chưa tới
-- 8 KB, nên 64 KB là rộng rãi mà vẫn giữ bảng nhẹ.
alter table public.courses drop constraint if exists courses_design_shape;
alter table public.courses add constraint courses_design_shape
  check (jsonb_typeof(design) = 'object' and length(design::text) <= 65536);

comment on column public.courses.design is
  'Phần mô tả dài của khoá học, sửa từ trang quản trị: bảng màu, bộ ảnh, các dải giới thiệu / phương pháp / vì sao chọn, hàng bảo chứng và hạng trình bày. Để {} thì trang dùng bản viết sẵn trong index.html.';
