-- ============================================================================
-- ĐÁNH GIÁ SẢN PHẨM — ĐÓNG CỬA ĐỌC THẲNG BẢNG
--
-- File trước (2026-09-23_1) mở bảng public.product_reviews cho mọi người đọc:
--
--   grant select on public.product_reviews to anon, authenticated;
--   create policy "Ai cũng xem được đánh giá sản phẩm" ... using (true);
--
-- Ý định thì đúng — đánh giá là thứ khách cần xem trước khi mua — nhưng làm
-- vậy thì hở hai chỗ:
--
--   1. Ẩn một bài không còn nghĩa là ẩn. Trang quản trị hứa "ẩn là nó biến
--      khỏi trang ngoài", và trang bán hàng có lọc is_hidden thật. Nhưng bảng
--      mở thì ai cũng gọi được
--        /rest/v1/product_reviews?select=*
--      và đọc lại đúng bài studio vừa ẩn. Bài bị ẩn thường là bài có nội dung
--      không nên để ai đọc — giấu bằng một câu lọc ở trình duyệt không phải
--      là giấu.
--
--   2. Lộ user_id. Cột ấy là mã tài khoản trong auth.users. Bảng mở thì một
--      người lạ tải về được cặp (user_id, product_key) của mọi khách từng
--      đánh giá — tức là biết ai đã mua gì.
--
-- Lối đúng đã có sẵn ngay bên cạnh: đánh giá khoá học (public.course_reviews)
-- chưa bao giờ mở bảng cho anon. Khách đọc qua course_reviews_get — một hàm
-- security definer chỉ trả ra đúng mấy trường cần hiện, không có user_id,
-- không có bài đã ẩn. File này kéo đánh giá sản phẩm về đúng lối ấy:
--
--   · Thu lại quyền đọc bảng của anon. Khách chưa đăng nhập đọc đánh giá qua
--     product_reviews_get (đã có từ file trước) — vẫn công khai như cũ, chỉ là
--     đi qua cửa có người soát thay vì cửa để ngỏ.
--   · Người đã đăng nhập chỉ còn thấy bài của chính mình trong bảng; quản trị
--     thấy tất cả, kể cả bài đã ẩn, vì trang quản trị đọc thẳng bảng.
--   · Thêm public.product_reviews_stats() cho điểm sao trên thẻ ngoài lưới —
--     chỗ duy nhất trang bán hàng còn cần đọc thẳng bảng. Hàm trả về mỗi món
--     một cặp số đếm và tổng sao, không kèm bài vở gì, nên không lộ gì cả.
--
-- Chạy sau 2026-09-23_1_danh_gia_san_pham.sql.
-- ============================================================================

-- 1. Đóng cửa đọc thẳng ------------------------------------------------------
-- Không còn ai đọc bảng bằng khoá công khai. Hai hàm product_reviews_get và
-- save_product_review là security definer nên không hề gì — chúng đọc bảng
-- bằng quyền của chủ hàm, không phải quyền của người gọi.
revoke select on public.product_reviews from anon;

drop policy if exists "Ai cũng xem được đánh giá sản phẩm" on public.product_reviews;

-- Người đã đăng nhập thấy đúng bài của mình (để sửa lại, để xoá đi); quản trị
-- thấy tất cả vì trang quản trị cần cả bài đã ẩn để bấm "Hiện lại".
drop policy if exists "Khách xem được đánh giá của mình" on public.product_reviews;
create policy "Khách xem được đánh giá của mình" on public.product_reviews
  for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

-- 2. Điểm sao trên thẻ ngoài lưới --------------------------------------------
-- Lưới sản phẩm cần biết mỗi món được mấy đánh giá và tổng bao nhiêu sao, để
-- cộng với điểm nền trong products.rate / products.reviews rồi chia ra điểm
-- hiện trên thẻ. Trước đây trang lấy hai con số ấy bằng cách tải về từng dòng
-- đánh giá rồi tự cộng — nay hỏi một câu, máy chủ cộng sẵn.
--
-- Trả về một cục jsonb lấy mã món làm khoá, để trang tra trực tiếp:
--   { "tham": { "count": 3, "sum": 14 }, "binh": { "count": 1, "sum": 5 } }
-- Món chưa ai đánh giá thì không có khoá — trang hiểu là 0.
-- Bài đã ẩn không được đếm, nên ẩn một bài là điểm trung bình đổi theo ngay.
create or replace function public.product_reviews_stats()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(
    jsonb_object_agg(t.product_key, jsonb_build_object('count', t.n, 'sum', t.s)),
    '{}'::jsonb
  )
  from (
    select product_key, count(*) as n, sum(rating) as s
    from public.product_reviews
    where not is_hidden
    group by product_key
  ) t;
$function$;

comment on function public.product_reviews_stats() is
  'Số đánh giá và tổng sao của từng món, cho điểm sao trên thẻ ngoài lưới. Không kèm nội dung và không kèm mã người viết.';

revoke all on function public.product_reviews_stats() from public;
grant execute on function public.product_reviews_stats() to anon, authenticated;
