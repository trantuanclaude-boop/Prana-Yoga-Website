-- ============================================================================
-- SOÁT LẠI ĐÁNH GIÁ SẢN PHẨM — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó cắm một đánh giá giả vào
-- bảng, xem mấy con số có nhảy đúng hay không, rồi tự ném lỗi ở dòng cuối để
-- cả giao dịch quay về như cũ — workflow chạy với --single-transaction nên sai
-- một câu là không còn dấu vết nào. Nghĩa là lần chạy này BÁO ĐỎ mới là đúng;
-- xem kết quả trong nhật ký, ở mấy dòng NOTICE.
--
-- Soát bốn điều:
--   1. Cắm một đánh giá thì product_reviews_stats() đếm được nó.
--   2. Ẩn nó đi thì stats và product_reviews_get đều bỏ nó ra.
--   3. Người chưa mua món gọi save_product_review thì bị chặn 'not_purchased'.
--   4. Người đã mua thật thì ghi được, và ghi lần hai là sửa chứ không đẻ dòng.
-- ============================================================================
do $do$
declare
  v_user  uuid;
  v_prod  text;
  v_order uuid;
  v_stats jsonb;
  v_get   jsonb;
  v_err   text;
begin
  select id into v_user from auth.users order by created_at limit 1;
  select key into v_prod from public.products where is_active order by key limit 1;
  if v_user is null or v_prod is null then
    raise exception 'Chưa có người dùng hoặc sản phẩm nào để thử.';
  end if;
  raise notice 'Thử trên người % và món %', v_user, v_prod;

  -- 1. Cắm một đánh giá, stats phải đếm được -------------------------------
  insert into public.product_reviews (product_key, user_id, rating, body, author_name)
  values (v_prod, v_user, 4, 'Đánh giá thử, sẽ bị quay đầu.', 'Người thử')
  on conflict (product_key, user_id) do update
    set rating = 4, body = excluded.body, is_hidden = false;

  v_stats := public.product_reviews_stats();
  raise notice '1. stats sau khi cắm: %', v_stats -> v_prod;
  if (v_stats -> v_prod ->> 'count')::int < 1 then
    raise exception 'SAI 1: stats không đếm đánh giá vừa cắm.';
  end if;

  -- 2. Ẩn đi thì phải biến khỏi cả stats lẫn get ----------------------------
  update public.product_reviews set is_hidden = true
   where product_key = v_prod and user_id = v_user;

  v_stats := public.product_reviews_stats();
  v_get   := public.product_reviews_get(v_prod);
  raise notice '2. sau khi ẩn — stats: %, get.count: %, get.items: %',
    coalesce((v_stats -> v_prod)::text, '(không còn khoá)'),
    v_get ->> 'count', jsonb_array_length(v_get -> 'items');
  if jsonb_array_length(v_get -> 'items') <> 0 then
    raise exception 'SAI 2: đánh giá đã ẩn vẫn hiện trong product_reviews_get.';
  end if;

  delete from public.product_reviews where product_key = v_prod and user_id = v_user;

  -- 3. Chưa mua thì không ghi được -----------------------------------------
  -- Mượn danh người ấy đúng cách Supabase làm: đặt request.jwt.claims cho
  -- auth.uid() trả về mã người dùng, rồi hạ quyền xuống vai authenticated.
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
    begin
      perform public.save_product_review(v_prod, 5, 'Chưa mua mà vẫn viết được?');
      v_err := '(không báo lỗi gì)';
    exception when others then
      v_err := sqlerrm;
    end;
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end;
  raise notice '3. chưa mua mà gửi — máy chủ trả: %', v_err;
  if v_err <> 'not_purchased' then
    raise exception 'SAI 3: đợi ''not_purchased'', nhận ''%''.', v_err;
  end if;

  -- 4. Mua rồi thì ghi được, gửi lần hai là sửa -----------------------------
  insert into public.orders (
    code, user_id, kind, item_key, item_name, plan,
    base_vnd, discount_vnd, vat_vnd, total_vnd,
    method, status, buyer_name, buyer_phone, buyer_email
  ) values (
    'PY-THUTHU1', v_user, 'shop', 'shop', 'Đơn thử', 'shop',
    1000, 0, 0, 1000,
    'card', 'paid', 'Người thử', '0900000000', 'thu@vidu.test'
  )
  returning id into v_order;
  insert into public.order_items (
    order_id, position, product_key, product_name,
    color_idx, size_idx, qty, unit_vnd, line_vnd
  ) values (v_order, 1, v_prod, 'Món thử', 0, 0, 1, 1000, 1000);

  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
    perform public.save_product_review(v_prod, 5, 'Lần đầu.');
    perform public.save_product_review(v_prod, 3, 'Sửa lại lần hai.');
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end;

  raise notice '4. mua rồi thì gửi được — số dòng: %, sao: %, lời: %',
    (select count(*) from public.product_reviews where product_key = v_prod and user_id = v_user),
    (select rating from public.product_reviews where product_key = v_prod and user_id = v_user),
    (select body   from public.product_reviews where product_key = v_prod and user_id = v_user);
  if (select count(*) from public.product_reviews
       where product_key = v_prod and user_id = v_user) <> 1 then
    raise exception 'SAI 4: gửi hai lần đẻ ra hơn một dòng.';
  end if;
  if (select rating from public.product_reviews
       where product_key = v_prod and user_id = v_user) <> 3 then
    raise exception 'SAI 4: gửi lần hai không sửa được sao.';
  end if;

  raise notice 'BỐN ĐIỀU ĐỀU ĐÚNG. Giờ ném lỗi để quay đầu, không để lại gì.';
  raise exception 'QUAY_DAU_THEO_Y_DINH';
end
$do$;
