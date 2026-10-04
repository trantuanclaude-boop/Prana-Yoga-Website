-- ============================================================================
-- SOÁT LẠI SỨC KHOẺ THƯƠNG HIỆU — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó nạp
-- 2026-10-04_1_suc_khoe_thuong_hieu.sql vào cùng một giao dịch, cắm một ít
-- lượt ghé và đơn giả vào tháng 1/2030 (để không lẫn với số thật), thử mọi
-- đường được và bị chặn, rồi tự ném lỗi ở dòng cuối để cả giao dịch quay về
-- như cũ. Lần chạy BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng.
--
-- Soát sáu điều:
--   1. Khách vãng lai (anon) ghi được loại việc mới kèm nguồn khách.
--   2. Loại việc lạ và nguồn khách quá dài bị chặn.
--   3. Khách thường gọi admin_brand_health thì bị chặn ('not_admin').
--   4. Quản trị gọi được; lượt của trình duyệt quản trị bị loại.
--   5. Các con số đếm đúng: người ghé, nguồn khách, xem khoá, vào thanh toán
--      rồi đặt đơn, người mua, đánh giá.
--   6. Bật p_with_staff thì lượt của quản trị được tính lại.
-- ============================================================================
\ir 2026-10-04_1_suc_khoe_thuong_hieu.sql

do $do$
declare
  v_user    uuid;
  v_founder uuid;
  v_err     text;
  r         jsonb;
  r2        jsonb;
  v_course  text;
  a timestamptz := '2030-01-01 00:00+07';
  b timestamptz := '2030-02-01 00:00+07';
begin
  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  if v_founder is null then raise exception 'SAI: không có ai trong public.staff để thử.'; end if;
  select c.key into v_course from public.courses c order by c.is_active desc, c.sort_order, c.key limit 1;

  -- Khách thường, quay đầu cùng giao dịch
  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-suc-khoe@vidu.test')
  returning id into v_user;
  raise notice 'Khách thử %, quản trị %', v_user, v_founder;

  -- 1. anon ghi được loại việc mới ------------------------------------------
  set local role anon;
  insert into public.site_events (visitor, kind, item_key, source)
  values ('vthukhachle01', 'visit', '', 'direct');
  insert into public.site_events (visitor, kind, item_key)
  values ('vthukhachle01', 'stay', ''), ('vthukhachle01', 'product', 'tham-tap'),
         ('vthukhachle01', 'pricing', ''), ('vthukhachle01', 'cart', 'tham-tap'),
         ('vthukhachle01', 'chat', '');
  raise notice '1. anon ghi được visit/stay/product/pricing/cart/chat';

  -- 2. Bị chặn: loại lạ, nguồn quá dài --------------------------------------
  begin
    insert into public.site_events (visitor, kind) values ('vthukhachle01', 'hack');
    v_err := '(không bị chặn)';
  exception when check_violation then v_err := 'bị chặn';
  end;
  raise notice '2a. loại việc lạ: %', v_err;
  if v_err <> 'bị chặn' then raise exception 'SAI 2a: loại việc lạ lọt qua.'; end if;
  begin
    insert into public.site_events (visitor, kind, source) values ('vthukhachle01', 'visit', repeat('x', 61));
    v_err := '(không bị chặn)';
  exception when check_violation then v_err := 'bị chặn';
  end;
  raise notice '2b. nguồn khách 61 ký tự: %', v_err;
  if v_err <> 'bị chặn' then raise exception 'SAI 2b: nguồn khách quá dài lọt qua.'; end if;
  reset role;

  -- Dời mấy dòng vừa ghi sang tháng 1/2030 và cắm thêm số liệu giả ------------
  update public.site_events set created_at = '2030-01-05 09:00+07' where visitor = 'vthukhachle01';
  insert into public.site_events (visitor, user_id, kind, item_key, source, created_at) values
    -- Khách có tài khoản: tới từ Google, ghé hai ngày, xem khoá, vào thanh toán
    ('vthukhachtk01', null,   'visit',    '',            'search:google', '2030-01-06 08:00+07'),
    ('vthukhachtk01', null,   'course',   v_course,     '',              '2030-01-06 08:01+07'),
    ('vthukhachtk01', null,   'checkout', v_course,     '',              '2030-01-06 08:02+07'),
    ('vthukhachtk01', v_user, 'visit',    '',            'direct',        '2030-01-09 08:00+07'),
    -- Trình duyệt của quản trị: phải bị loại
    ('vthuquantri01', null,      'visit',  '',        'direct', '2030-01-07 08:00+07'),
    ('vthuquantri01', v_founder, 'course', v_course, '',       '2030-01-07 08:05+07');

  insert into public.orders (
    code, user_id, kind, item_key, item_name, plan,
    base_vnd, discount_vnd, vat_vnd, total_vnd,
    method, status, buyer_name, buyer_phone, buyer_email, created_at
  ) values
    ('PY-THUSK01', v_user, 'course', v_course, 'Khoá thử', 'full',
     1000000, 0, 80000, 1080000, 'bank', 'paid', 'Người thử', '0900000000', 'thu@vidu.test', '2030-01-06 08:10+07'),
    ('PY-THUSK02', v_founder, 'course', v_course, 'Đơn thử của quản trị', 'full',
     1000000, 0, 80000, 1080000, 'bank', 'paid', 'Quản trị', '0900000000', 'qt@vidu.test', '2030-01-07 08:10+07');

  insert into public.course_reviews (user_id, course_key, rating, body, author_name, created_at)
  values (v_user, v_course, 5, 'Thử', 'Người thử', '2030-01-10 08:00+07');

  -- 3. Khách thường bị chặn --------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  begin
    perform public.admin_brand_health(a, b, false);
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '3. khách thường gọi: %', v_err;
  if v_err <> 'not_admin' then raise exception 'SAI 3: khách thường không bị chặn.'; end if;

  -- 4–5. Quản trị gọi --------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  r := public.admin_brand_health(a, b, false);
  raise notice '4. traffic: %', r->'traffic';
  raise notice '   interest: %', r->'interest';
  raise notice '   conversion: %', r->'conversion';
  raise notice '   loyalty: %', r->'loyalty';
  raise notice '   satisfaction: %', r->'satisfaction';
  raise notice '   service: %', r->'service';
  raise notice '   top_items: %', r->'top_items';

  if (r->'traffic'->>'visitors')::int <> 2 then
    raise exception 'SAI 4: người ghé phải là 2 (không tính trình duyệt quản trị), ra %', r->'traffic'->>'visitors';
  end if;
  if (r->'traffic'->>'returning')::int <> 1 then raise exception 'SAI 5: người ghé lại phải là 1.'; end if;
  if coalesce((r->'traffic'->'sources'->>'search')::int, 0) <> 1
     or coalesce((r->'traffic'->'sources'->>'direct')::int, 0) <> 1 then
    raise exception 'SAI 5: nguồn khách phải là 1 search + 1 direct, ra %', r->'traffic'->'sources';
  end if;
  if (r->'interest'->>'course')::int <> 1 or (r->'interest'->>'interested')::int <> 2
     or (r->'interest'->>'stayed')::int <> 1 or (r->'interest'->>'checkout')::int <> 1 then
    raise exception 'SAI 5: số quan tâm sai: %', r->'interest';
  end if;
  if (r->'conversion'->>'checkout_ordered')::int <> 1 then
    raise exception 'SAI 5: vào thanh toán rồi đặt đơn phải là 1.';
  end if;
  if (r->'conversion'->>'buyers')::int <> 1 or (r->'conversion'->>'paid')::int <> 1 then
    raise exception 'SAI 5: người mua / đơn đã trả phải là 1 (không tính đơn quản trị).';
  end if;
  if (r->'satisfaction'->>'reviews')::int < 1 then
    raise exception 'SAI 5: phải thấy đánh giá vừa cắm.';
  end if;

  -- 6. Tính cả quản trị -------------------------------------------------------
  r2 := public.admin_brand_health(a, b, true);
  raise notice '6. có tính quản trị — người ghé %, đơn đã trả %',
    r2->'traffic'->>'visitors', r2->'conversion'->>'paid';
  if (r2->'traffic'->>'visitors')::int <> 3 or (r2->'conversion'->>'paid')::int <> 2 then
    raise exception 'SAI 6: bật p_with_staff mà vẫn không tính quản trị.';
  end if;

  -- Phễu Tổng quan vẫn chạy
  raise notice '   admin_funnel: %', public.admin_funnel(a, b);

  reset role;
  raise exception 'QUAY_DAU_THEO_Y_DINH — mọi điều soát đã qua, giờ quay đầu.';
end;
$do$;
