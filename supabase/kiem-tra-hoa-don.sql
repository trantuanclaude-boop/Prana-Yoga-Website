-- ============================================================================
-- SOÁT LẠI HOÁ ĐƠN — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó nạp
-- 2026-10-11_1_hoa_don.sql vào cùng một giao dịch, tạo một khách thử với hai
-- đơn giả, thử mọi đường được và bị chặn, rồi tự ném lỗi ở dòng cuối để cả
-- giao dịch quay về như cũ. Lần chạy BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng.
--
-- Soát bảy điều:
--   1. Đơn thẻ ghi "đã thanh toán" ngay lúc đặt thì có paid_at luôn.
--   2. Đơn chuyển khoản còn chờ thì paid_at trống.
--   3. Quản trị bấm "Đã nhận tiền" → có paid_at, sổ ghi đúng người bấm.
--   4. Khách đọc được paid_at của đơn mình.
--   5. Khách không đọc được sổ, không gọi được admin_order_log.
--   6. Quản trị đọc sổ ra tên, email, bậc của người bấm.
--   7. Trả về "chờ" thì paid_at trống lại; huỷ thì giữ ngày cũ.
-- ============================================================================
\ir 2026-10-11_1_hoa_don.sql

do $do$
declare
  v_user    uuid;
  v_founder uuid;
  v_card    uuid;
  v_bank    uuid;
  v_paid    timestamptz;
  v_n       integer;
  v_err     text;
  r         record;
begin
  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  if v_founder is null then raise exception 'SAI: không có ai trong public.staff để thử.'; end if;

  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-hoa-don@vidu.test')
  returning id into v_user;
  raise notice 'Khách thử %, quản trị %', v_user, v_founder;

  -- 1. Đơn thẻ: đã thanh toán ngay lúc đặt ------------------------------------
  insert into public.orders (
    code, user_id, kind, item_key, item_name, plan,
    base_vnd, discount_vnd, coupon_code, vat_vnd, total_vnd,
    method, status, buyer_name, buyer_phone, buyer_email, ship_address, ship_note
  ) values (
    'PY-THUHD001', v_user, 'shop', 'shop', 'Món thử', 'shop',
    500000, 0, null, 0, 500000,
    'card', 'paid', 'Khách Thử', '0900000000', 'thu-hoa-don@vidu.test', 'Số 1 đường Thử, Lào Cai', ''
  ) returning id, paid_at into v_card, v_paid;
  raise notice '1. đơn thẻ: paid_at = %', v_paid;
  if v_paid is null then raise exception 'SAI 1: đơn thẻ đã trả mà không có paid_at.'; end if;

  -- 2. Đơn chuyển khoản còn chờ ------------------------------------------------
  insert into public.orders (
    code, user_id, kind, item_key, item_name, plan,
    base_vnd, discount_vnd, coupon_code, vat_vnd, total_vnd,
    method, status, buyer_name, buyer_phone, buyer_email, ship_address, ship_note,
    transfer_proof, transfer_proof_at, transfer_ref
  ) values (
    'PY-THUHD002', v_user, 'shop', 'shop', 'Món thử', 'shop',
    300000, 0, null, 0, 300000,
    'bank', 'pending', 'Khách Thử', '0900000000', 'thu-hoa-don@vidu.test', 'Số 1 đường Thử, Lào Cai', '',
    v_user::text || '/PY-THUHD002-1.jpg', now(), 'PRANA THUHD002'
  ) returning id, paid_at into v_bank, v_paid;
  raise notice '2. đơn chuyển khoản chờ: paid_at = %', coalesce(v_paid::text, '(trống)');
  if v_paid is not null then raise exception 'SAI 2: đơn còn chờ mà đã có paid_at.'; end if;

  -- 3. Quản trị bấm "Đã nhận tiền" -------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  perform public.admin_set_order_status(v_bank, 'paid');
  reset role;
  select o.paid_at into v_paid from public.orders o where o.id = v_bank;
  select count(*) into v_n from public.order_status_log l
  where l.order_id = v_bank and l.actor = v_founder and l.from_status = 'pending' and l.to_status = 'paid';
  raise notice '3. sau "Đã nhận tiền": paid_at = %, dòng sổ đúng người = %', v_paid, v_n;
  if v_paid is null then raise exception 'SAI 3a: duyệt xong mà không có paid_at.'; end if;
  if v_n <> 1 then raise exception 'SAI 3b: sổ không ghi đúng người bấm.'; end if;

  -- 4 + 5. Nhìn bằng mắt khách --------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  select o.paid_at into v_paid from public.orders o where o.id = v_bank;
  raise notice '4. khách đọc paid_at của đơn mình: %', coalesce(v_paid::text, '(không đọc được)');
  if v_paid is null then raise exception 'SAI 4: khách không đọc được paid_at.'; end if;

  begin
    select count(*) into v_n from public.order_status_log;
    v_err := '(không bị chặn, đọc được ' || v_n || ' dòng)';
  exception when insufficient_privilege then v_err := 'bị chặn';
  end;
  raise notice '5a. khách đọc thẳng sổ: %', v_err;
  if v_err <> 'bị chặn' then raise exception 'SAI 5a: khách đọc được sổ đổi trạng thái.'; end if;

  begin
    perform * from public.admin_order_log(v_bank);
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '5b. khách gọi admin_order_log: %', v_err;
  if v_err <> 'not_admin' then raise exception 'SAI 5b: khách gọi được admin_order_log.'; end if;
  reset role;

  -- 6. Quản trị đọc sổ -----------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  v_n := 0;
  for r in select * from public.admin_order_log(v_bank) loop
    v_n := v_n + 1;
    raise notice '6. sổ: % → % lúc % bởi "%" <%> bậc %',
      r.from_status, r.to_status, r.changed_at, r.by_name, r.by_email, r.by_role;
    if r.by_email = '' or r.by_role = '' then
      raise exception 'SAI 6: sổ không ra email / bậc của người bấm.';
    end if;
  end loop;
  if v_n <> 1 then raise exception 'SAI 6: sổ có % dòng, mong 1.', v_n; end if;

  -- 7. Trả về chờ rồi huỷ ----------------------------------------------------------
  perform public.admin_set_order_status(v_bank, 'pending');
  reset role;
  select o.paid_at into v_paid from public.orders o where o.id = v_bank;
  raise notice '7a. trả về chờ: paid_at = %', coalesce(v_paid::text, '(trống)');
  if v_paid is not null then raise exception 'SAI 7a: trả về chờ mà paid_at còn đó.'; end if;

  -- Từ đây là SQL gõ tay: không còn ai đăng nhập
  perform set_config('request.jwt.claims', '', true);
  select o.paid_at into v_paid from public.orders o where o.id = v_card;
  update public.orders set status = 'cancelled' where id = v_card;
  if (select o.paid_at from public.orders o where o.id = v_card) is distinct from v_paid then
    raise exception 'SAI 7b: huỷ đơn làm đổi paid_at.';
  end if;
  select count(*) into v_n from public.order_status_log l where l.order_id = v_card and l.actor is null;
  raise notice '7b. huỷ đơn thẻ: paid_at giữ nguyên, sổ ghi % dòng (người bấm trống vì là SQL)', v_n;
  if v_n <> 1 then raise exception 'SAI 7b: đổi trạng thái bằng SQL không vào sổ.'; end if;

  -- Đổi trạng thái mà vẫn là trạng thái cũ thì không ghi sổ
  update public.orders set status = 'cancelled' where id = v_card;
  select count(*) into v_n from public.order_status_log l where l.order_id = v_card;
  if v_n <> 1 then raise exception 'SAI 7c: ghi sổ cả khi trạng thái không đổi.'; end if;

  raise notice 'Qua cả bảy điều.';
  raise exception 'QUAY_DAU_THEO_Y_DINH';
end;
$do$;
