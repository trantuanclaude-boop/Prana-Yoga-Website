-- ============================================================================
-- ĐÁNH GIÁ SẢN PHẨM
--
-- Trước file này, số sao trên trang bán hàng là hai con số chết trong bảng
-- products: rate = 4.9, reviews = 214. Ai nhìn cũng thấy, nhưng không một
-- khách nào viết thêm được chữ nào.
--
-- File này mở đường cho khách viết thật, theo đúng lối khoá học đang đi
-- (public.course_reviews + course_reviews_get + save_review):
--
--   1. public.product_reviews — mỗi người một đánh giá cho mỗi món, sửa lại
--      được nhưng không thành hai dòng. Sao từ 1 đến 5, lời nhận xét có thể
--      để trống (chấm sao suông cũng là một ý kiến). Quản trị ẩn được một bài
--      qua trang quản trị: bài ấy biến khỏi trang bán hàng và khỏi điểm trung
--      bình, nhưng vẫn còn trong sổ.
--
--   2. public.product_reviews_get(p_product) — trả về đúng một cục jsonb cho
--      trang chi tiết: tổng số, tổng sao, và danh sách đánh giá kèm tên người
--      viết. Đọc được cả khi chưa đăng nhập, vì đây là thứ khách cần xem
--      trước khi quyết định mua.
--
--   3. public.save_product_review(p_product, p_rating, p_body) — cửa duy nhất
--      để ghi. Máy chủ tự kiểm tra người gửi đã thật sự mua món này chưa
--      (có dòng trong order_items thuộc một đơn đã thanh toán), tự lấy tên
--      từ hồ sơ. Chưa mua thì báo lỗi 'not_purchased' — trang dịch câu ấy ra
--      tiếng người.
--
-- Điểm nền cũ trong products.rate / products.reviews vẫn giữ nguyên và vẫn
-- được cộng vào điểm hiển thị, nên chạy file này xong trang không tụt từ
-- "4,9 · 214 đánh giá" xuống "5,0 · 1 đánh giá".
--
-- Chạy sau 2026-09-21_4_video_ngoai_rieng_tu.sql.
-- ============================================================================

-- 1. Bảng đánh giá -----------------------------------------------------------
create table if not exists public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_key text not null
    references public.products (key) on update cascade on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  body text not null default '' check (char_length(body) <= 1200),
  -- Tên chép lại lúc gửi, không đọc sang profiles mỗi lần hiện: đây là tên
  -- người ấy ký dưới bài, đổi tên ở hồ sơ về sau không sửa ngược bài cũ.
  -- Cùng lối với public.course_reviews.
  author_name text not null default '',
  -- Quản trị ẩn một bài là nó biến khỏi trang bán hàng nhưng vẫn còn trong sổ.
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_reviews_one_per_buyer unique (product_key, user_id)
);
comment on table public.product_reviews is
  'Đánh giá sản phẩm của khách. Mỗi người một dòng cho mỗi món — gửi lại là sửa dòng cũ, không đẻ dòng mới.';
comment on column public.product_reviews.body is
  'Lời nhận xét, được phép để trống: chấm sao suông vẫn tính vào điểm trung bình.';

create index if not exists product_reviews_product_idx
  on public.product_reviews (product_key, created_at desc);

drop trigger if exists product_reviews_touch on public.product_reviews;
create trigger product_reviews_touch before update on public.product_reviews
  for each row execute function private.touch_updated_at();

alter table public.product_reviews enable row level security;
revoke all on public.product_reviews from anon, authenticated;
grant select on public.product_reviews to anon, authenticated;
grant delete on public.product_reviews to authenticated;

-- Ai cũng đọc được: đây là thứ khách xem trước khi mua.
drop policy if exists "Ai cũng xem được đánh giá sản phẩm" on public.product_reviews;
create policy "Ai cũng xem được đánh giá sản phẩm" on public.product_reviews
  for select to anon, authenticated using (true);

-- Không có chính sách insert / update cho khách: muốn ghi thì đi qua
-- public.save_product_review, nơi máy chủ kiểm tra đã mua hàng hay chưa.
drop policy if exists "Khách xoá được đánh giá của mình" on public.product_reviews;
create policy "Khách xoá được đánh giá của mình" on public.product_reviews
  for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists "Quản trị quản đánh giá sản phẩm" on public.product_reviews;
create policy "Quản trị quản đánh giá sản phẩm" on public.product_reviews
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant insert, update on public.product_reviews to authenticated;

-- 2. Đã mua hay chưa ---------------------------------------------------------
-- Một dòng trong order_items thuộc đơn đã thanh toán của chính người đang
-- đăng nhập. Hàm không nhận vào mã người dùng — nó chỉ tự hỏi về chính người
-- gọi, nên không ai mượn nó để dò xem người khác đã mua những gì.
-- Trang chi tiết gọi thẳng hàm này để biết có nên bày ô viết đánh giá hay không.
create or replace function public.has_bought_product(p_product text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.product_key = p_product
      and o.user_id = (select auth.uid())
      and o.status = 'paid'
  );
$function$;

revoke all on function public.has_bought_product(text) from public, anon;
grant execute on function public.has_bought_product(text) to authenticated;

-- 3. Đọc đánh giá của một món ------------------------------------------------
-- Trả về một cục jsonb đúng hình trang chi tiết cần:
--   { "count": 3, "sum": 14, "can": true,
--     "items": [ { rating, body, author, at, mine } ] }
-- count và sum để trang cộng với điểm nền của món rồi chia ra điểm hiển thị.
-- can là "người đang xem có mua món này chưa" — hỏi luôn ở đây để trang khỏi
-- phải gọi thêm một lượt nữa mới biết có nên bày ô viết hay không.
-- Mới nhất đứng trước, lấy tối đa 60 dòng — đủ cho một trang sản phẩm.
create or replace function public.product_reviews_get(p_product text)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  -- count và sum đếm trên toàn bộ đánh giá của món, không chỉ 60 dòng lấy về:
  -- trang cộng hai con số này với điểm nền rồi chia ra điểm hiển thị, mà điểm
  -- ấy phải khớp với con số trên thẻ ngoài lưới — nơi đếm tất cả.
  select jsonb_build_object(
    'count', (select count(*) from public.product_reviews
               where product_key = p_product and not is_hidden),
    'sum',   (select coalesce(sum(rating), 0) from public.product_reviews
               where product_key = p_product and not is_hidden),
    'can',   public.has_bought_product(p_product),
    'items', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'rating', r.rating,
          'body',   r.body,
          'author', coalesce(nullif(trim(r.author_name), ''), 'Khách hàng'),
          'at',     r.created_at,
          'mine',   r.user_id = (select auth.uid())
        )
        order by (r.user_id = (select auth.uid())) desc, r.created_at desc
      ), '[]'::jsonb)
      from (
        select * from public.product_reviews
        where product_key = p_product and not is_hidden
        order by created_at desc
        limit 60
      ) r
    )
  );
$function$;

revoke all on function public.product_reviews_get(text) from public;
grant execute on function public.product_reviews_get(text) to anon, authenticated;

-- 4. Gửi đánh giá ------------------------------------------------------------
-- Cửa duy nhất để ghi. Người gửi phải đăng nhập và phải đã mua món này trong
-- một đơn đã thanh toán — nếu không, hàm ném 'not_purchased' để trang hiện
-- câu "Chỉ khách đã mua sản phẩm này mới gửi được đánh giá".
-- Gửi lần hai là sửa lại đánh giá lần đầu, không thành hai dòng.
create or replace function public.save_product_review(
  p_product text,
  p_rating  integer,
  p_body    text default ''
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user uuid := (select auth.uid());
  v_body text := left(trim(coalesce(p_body, '')), 1200);
begin
  if v_user is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'bad_rating' using errcode = '22023';
  end if;
  if not exists (select 1 from public.products where key = p_product and is_active) then
    raise exception 'no_product' using errcode = '23503';
  end if;
  if not public.has_bought_product(p_product) then
    raise exception 'not_purchased' using errcode = '42501';
  end if;

  insert into public.product_reviews (product_key, user_id, rating, body, author_name)
  values (
    p_product, v_user, p_rating, v_body,
    coalesce(
      (select nullif(trim(full_name), '') from public.profiles where id = v_user),
      'Khách hàng'
    )
  )
  on conflict (product_key, user_id) do update
    set rating      = excluded.rating,
        body        = excluded.body,
        author_name = excluded.author_name;

  return public.product_reviews_get(p_product);
end;
$function$;

revoke all on function public.save_product_review(text, integer, text) from public, anon;
grant execute on function public.save_product_review(text, integer, text) to authenticated;
