-- ============================================================================
-- SOÁT LẠI NGỌN LỬA THEO CHUỖI — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó nạp
-- 2026-10-17_2_ngon_lua_chuoi.sql vào cùng một giao dịch, thử sửa bậc lửa bằng
-- tài khoản quản trị và tài khoản khách, rồi tự ném lỗi ở dòng cuối để cả giao
-- dịch quay về như cũ. Lần chạy BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng.
--
-- Soát năm điều:
--   1. Bộ mặc định hợp lệ, khách vãng lai đọc được hai cột mới.
--   2. Quản trị lưu được bậc lửa xếp lộn xộn; máy chủ xếp lại tăng dần.
--   3. Mảng hỏng bị chặn: màu sai, from 0 / chữ, trùng from, 9 bậc, tên trống,
--      thiếu màu, không phải mảng.
--   4. Quản trị tắt được ngọn lửa cạnh ảnh đại diện.
--   5. Khách đăng nhập không sửa được bậc lửa.
-- ============================================================================
\ir 2026-10-17_2_ngon_lua_chuoi.sql

do $do$
declare
  v_founder uuid;
  v_guest   uuid;
  v_j       jsonb;
  v_n       integer;
  v_err     text;
  v_bad     jsonb;
  v_label   text;
  v_ok      boolean;
begin
  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  if v_founder is null then raise exception 'SAI: không có ai trong public.staff để thử.'; end if;

  -- 1. Bộ mặc định, khách vãng lai đọc -------------------------------------------
  select flames into v_j from public.streak_settings where id = 1;
  raise notice '1a. bậc lửa đang có: % bậc, hợp lệ = %', jsonb_array_length(v_j), private.streak_flames_ok(v_j);
  if not private.streak_flames_ok(v_j) then raise exception 'SAI 1a: bộ mặc định không hợp lệ.'; end if;
  set local role anon;
  select count(*) into v_n from public.streak_settings where id = 1 and flame_badge and jsonb_array_length(flames) >= 1;
  raise notice '1b. khách vãng lai đọc được flames / flame_badge: % dòng', v_n;
  if v_n <> 1 then raise exception 'SAI 1b: khách vãng lai không đọc được hai cột mới.'; end if;
  reset role;

  -- 2. Quản trị lưu bậc xếp lộn xộn -----------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  update public.streak_settings set flames =
    '[{"from":30,"vi":"Lửa xanh","en":"","c":["#123fbf","#2e8bff","#b5ecff"]},
      {"from":1,"vi":"Lửa cam","c":["#D9481F","#f08a2c","#ffd27a"]},
      {"from":10,"vi":"Lửa đỏ","en":"Red","c":["#a50f2d","#e8322b","#ff9e6b"]}]'::jsonb
  where id = 1;
  get diagnostics v_n = row_count;
  select flames into v_j from public.streak_settings where id = 1;
  raise notice '2. quản trị lưu: % dòng đổi → %', v_n,
    (select string_agg(e->>'from', ', ' order by o) from jsonb_array_elements(v_j) with ordinality t(e, o));
  if v_n <> 1 then raise exception 'SAI 2a: quản trị không sửa được bậc lửa.'; end if;
  if (select string_agg(e->>'from', ',' order by o) from jsonb_array_elements(v_j) with ordinality t(e, o)) <> '1,10,30' then
    raise exception 'SAI 2b: máy chủ không xếp bậc lửa tăng dần.';
  end if;

  -- 3. Mảng hỏng ------------------------------------------------------------------
  for v_label, v_bad in
    select * from (values
      ('màu thiếu một chữ số', '[{"from":1,"vi":"A","c":["#12345","#000000","#ffffff"]}]'::jsonb),
      ('from = 0',             '[{"from":0,"vi":"A","c":["#111111","#000000","#ffffff"]}]'::jsonb),
      ('from là chữ',          '[{"from":"abc","vi":"A","c":["#111111","#000000","#ffffff"]}]'::jsonb),
      ('from 1001',            '[{"from":1001,"vi":"A","c":["#111111","#000000","#ffffff"]}]'::jsonb),
      ('trùng from',           '[{"from":5,"vi":"A","c":["#111111","#000000","#ffffff"]},{"from":5,"vi":"B","c":["#111111","#000000","#ffffff"]}]'::jsonb),
      ('tên trống',            '[{"from":1,"vi":"  ","c":["#111111","#000000","#ffffff"]}]'::jsonb),
      ('tên quá 40 ký tự',     jsonb_build_array(jsonb_build_object('from', 1, 'vi', repeat('a', 41), 'c', '["#111111","#000000","#ffffff"]'::jsonb))),
      ('chỉ hai màu',          '[{"from":1,"vi":"A","c":["#111111","#000000"]}]'::jsonb),
      ('mảng rỗng',            '[]'::jsonb),
      ('không phải mảng',      '{"from":1}'::jsonb),
      ('chín bậc',             (select jsonb_agg(jsonb_build_object('from', g, 'vi', 'L' || g, 'c', '["#111111","#000000","#ffffff"]'::jsonb)) from generate_series(1, 9) g))
    ) t(l, j)
  loop
    begin
      update public.streak_settings set flames = v_bad where id = 1;
      v_err := '(không bị chặn)';
    exception when others then v_err := sqlerrm;
    end;
    raise notice '3. % → %', v_label, v_err;
    if v_err = '(không bị chặn)' then raise exception 'SAI 3: mảng hỏng (%) vẫn lưu được.', v_label; end if;
  end loop;

  -- 4. Tắt ngọn lửa cạnh ảnh đại diện ---------------------------------------------
  update public.streak_settings set flame_badge = false where id = 1;
  select flame_badge into v_ok from public.streak_settings where id = 1;
  raise notice '4. flame_badge sau khi tắt: %', v_ok;
  if v_ok then raise exception 'SAI 4: quản trị không tắt được ngọn lửa.'; end if;
  reset role;

  -- 5. Khách đăng nhập ----------------------------------------------------------------
  insert into auth.users (id, aud, role, email)
    values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-ngon-lua@vidu.test') returning id into v_guest;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_guest, 'role', 'authenticated')::text, true);
  update public.streak_settings set flame_badge = true,
    flames = '[{"from":1,"vi":"Của tôi","c":["#000000","#000000","#000000"]}]'::jsonb where id = 1;
  get diagnostics v_n = row_count;
  raise notice '5. khách sửa bậc lửa: % dòng đổi', v_n;
  if v_n <> 0 then raise exception 'SAI 5: khách sửa được bậc lửa.'; end if;
  reset role;

  raise exception 'QUAY_DAU_THEO_Y_DINH — mọi điều đều đúng, giao dịch quay về như cũ.';
end
$do$;
