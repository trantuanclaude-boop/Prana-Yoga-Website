-- ============================================================================
-- SOÁT LẠI ĐỘ BÙNG CHÁY BẬC LỬA — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Nạp 2026-10-18_1_ngon_lua_hieu_ung.sql vào cùng một giao dịch, thử lưu fx
-- bằng tài khoản quản trị, rồi tự ném lỗi ở dòng cuối để mọi thứ quay về như cũ.
-- Lần chạy BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng.
--
--   1. Bậc đang lưu đã được điền fx đủ cả.
--   2. fx 1–3 lưu được; thiếu fx vẫn lưu được.
--   3. fx 0, 4, 2.5, "2" (chuỗi) bị chặn.
-- ============================================================================
\ir 2026-10-18_1_ngon_lua_hieu_ung.sql

do $do$
declare
  v_founder uuid;
  v_j       jsonb;
  v_n       integer;
  v_err     text;
  v_label   text;
  v_bad     jsonb;
begin
  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  if v_founder is null then raise exception 'SAI: không có ai trong public.staff để thử.'; end if;

  select flames into v_j from public.streak_settings where id = 1;
  select count(*) into v_n from jsonb_array_elements(v_j) e where not (e ? 'fx');
  raise notice '1. bậc đang lưu: % bậc, thiếu fx: % — fx = %', jsonb_array_length(v_j), v_n,
    (select string_agg(e->>'fx', ',' order by o) from jsonb_array_elements(v_j) with ordinality t(e, o));
  if v_n <> 0 then raise exception 'SAI 1: còn bậc chưa có fx.'; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  update public.streak_settings set flames =
    '[{"from":1,"vi":"Lửa cam","c":["#d9481f","#f08a2c","#ffd27a"],"fx":1},
      {"from":7,"vi":"Lửa đỏ","c":["#a50f2d","#e8322b","#ff9e6b"],"fx":3},
      {"from":21,"vi":"Lửa vàng","c":["#b86a00","#f2b01e","#fff3b0"]}]'::jsonb where id = 1;
  get diagnostics v_n = row_count;
  raise notice '2. lưu fx 1 / 3 / (thiếu): % dòng đổi', v_n;
  if v_n <> 1 then raise exception 'SAI 2: không lưu được fx hợp lệ.'; end if;

  for v_label, v_bad in
    select * from (values
      ('fx = 0',   '[{"from":1,"vi":"A","c":["#111111","#000000","#ffffff"],"fx":0}]'::jsonb),
      ('fx = 4',   '[{"from":1,"vi":"A","c":["#111111","#000000","#ffffff"],"fx":4}]'::jsonb),
      ('fx = 2.5', '[{"from":1,"vi":"A","c":["#111111","#000000","#ffffff"],"fx":2.5}]'::jsonb),
      ('fx chuỗi', '[{"from":1,"vi":"A","c":["#111111","#000000","#ffffff"],"fx":"2"}]'::jsonb)
    ) t(l, j)
  loop
    begin
      update public.streak_settings set flames = v_bad where id = 1;
      v_err := '(không bị chặn)';
    exception when others then v_err := sqlerrm;
    end;
    raise notice '3. % → %', v_label, v_err;
    if v_err = '(không bị chặn)' then raise exception 'SAI 3: % vẫn lưu được.', v_label; end if;
  end loop;
  reset role;

  raise exception 'QUAY_DAU_THEO_Y_DINH — mọi điều đều đúng, giao dịch quay về như cũ.';
end
$do$;
