-- ============================================================================
-- SOÁT LẠI ẢNH CHUYỂN KHOẢN — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó nạp
-- 2026-09-25_1_anh_chuyen_khoan.sql vào cùng một giao dịch, cắm hai đơn giả,
-- thử mọi đường được và bị chặn, rồi tự ném lỗi ở dòng cuối để cả giao dịch
-- quay về như cũ (workflow chạy với --single-transaction). Nghĩa là lần chạy
-- này BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng; xem mấy dòng NOTICE.
--
-- Soát sáu điều:
--   1. Câu dặn khách có sẵn chữ mặc định.
--   2. Đơn chuyển khoản của mình thì được tải ảnh vào kho; đơn trả thẻ, đơn
--      người khác, hay tên tệp lạ thì không.
--   3. Gắn ảnh vào đơn chuyển khoản thì ba cột ảnh được ghi.
--   4. Đơn trả thẻ thì không gắn được ('not_transfer').
--   5. Đường dẫn của đơn khác thì bị chặn ('path_invalid').
--   6. Tệp chưa tải lên thì bị chặn ('file_missing').
-- ============================================================================
\ir 2026-09-25_1_anh_chuyen_khoan.sql

do $do$
declare
  v_user  uuid;
  v_other text := '00000000-0000-4000-8000-000000000000';
  v_ck    text;
  v_card  text;
  v_err   text;
  v_ok    boolean;
  v_row   record;
begin
  -- Người thử phải là khách thường: người dùng có sẵn duy nhất là founder, mà
  -- quyền quản trị được ghi mọi thứ vào kho — thử bằng người đó thì mọi luật
  -- chặn khách đều "lọt" và phép thử nói sai. Người này quay đầu cùng giao dịch.
  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-chuyen-khoan@vidu.test')
  returning id into v_user;
  v_ck   := v_user::text || '/PY-THUCK01-1.jpg';
  v_card := v_user::text || '/PY-THUCK02-1.jpg';
  raise notice 'Thử trên người %', v_user;

  -- 1. Câu dặn khách -----------------------------------------------------------
  raise notice '1. proof_note: %', (select proof_note from public.payment_settings where id);
  if coalesce((select proof_note from public.payment_settings where id), '') = '' then
    raise exception 'SAI 1: proof_note trống.';
  end if;

  insert into public.orders (
    code, user_id, kind, item_key, item_name, plan,
    base_vnd, discount_vnd, vat_vnd, total_vnd,
    method, status, buyer_name, buyer_phone, buyer_email
  ) values
    ('PY-THUCK01', v_user, 'shop', 'shop', 'Đơn thử chuyển khoản', 'shop',
     1000, 0, 0, 1000, 'bank', 'pending', 'Người thử', '0900000000', 'thu@vidu.test'),
    ('PY-THUCK02', v_user, 'shop', 'shop', 'Đơn thử trả thẻ', 'shop',
     1000, 0, 0, 1000, 'card', 'paid', 'Người thử', '0900000000', 'thu@vidu.test');

  -- Mượn danh người ấy đúng cách Supabase làm
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 2. Ai được tải ảnh vào đâu -----------------------------------------------
  raise notice '2. được tải — đơn CK của mình: %, đơn thẻ: %, thư mục người khác: %, đơn không có: %, tên lạ: %',
    public.can_send_transfer_proof(v_ck),
    public.can_send_transfer_proof(v_card),
    public.can_send_transfer_proof(v_other || '/PY-THUCK01-1.jpg'),
    public.can_send_transfer_proof(v_user::text || '/PY-KHONGCO-1.jpg'),
    public.can_send_transfer_proof(v_user::text || '/../PY-THUCK01-1.jpg');
  if not public.can_send_transfer_proof(v_ck)
     or public.can_send_transfer_proof(v_card)
     or public.can_send_transfer_proof(v_other || '/PY-THUCK01-1.jpg')
     or public.can_send_transfer_proof(v_user::text || '/PY-KHONGCO-1.jpg')
     or public.can_send_transfer_proof(v_user::text || '/../PY-THUCK01-1.jpg') then
    raise exception 'SAI 2: luật tải ảnh không đúng.';
  end if;

  -- Tải thật qua RLS của storage.objects, đúng vai authenticated
  insert into storage.objects (bucket_id, name) values ('chuyen-khoan', v_ck);
  begin
    insert into storage.objects (bucket_id, name) values ('chuyen-khoan', v_card);
    v_err := '(không bị chặn)';
  exception when others then
    v_err := sqlerrm;
  end;
  raise notice '2b. tải ảnh cho đơn trả thẻ — máy chủ trả: %', v_err;
  if v_err = '(không bị chặn)' then
    raise exception 'SAI 2b: tải được ảnh cho đơn không phải chuyển khoản.';
  end if;

  -- 3. Gắn ảnh vào đơn chuyển khoản ------------------------------------------
  perform public.attach_transfer_proof('PY-THUCK01', v_ck, 'PRANA SH123456');
  select transfer_proof, transfer_proof_at, transfer_ref into v_row
  from public.orders where code = 'PY-THUCK01';
  raise notice '3. sau khi gắn: proof=%, at=%, ref=%', v_row.transfer_proof, v_row.transfer_proof_at, v_row.transfer_ref;
  if v_row.transfer_proof <> v_ck or v_row.transfer_proof_at is null or v_row.transfer_ref <> 'PRANA SH123456' then
    raise exception 'SAI 3: ba cột ảnh không được ghi đúng.';
  end if;

  -- 4. Đơn trả thẻ -------------------------------------------------------------
  begin
    perform public.attach_transfer_proof('PY-THUCK02', v_card, '');
    v_err := '(không báo lỗi gì)';
  exception when others then
    v_err := sqlerrm;
  end;
  raise notice '4. gắn ảnh cho đơn trả thẻ — máy chủ trả: %', v_err;
  if v_err <> 'not_transfer' then
    raise exception 'SAI 4: đợi ''not_transfer'', nhận ''%''.', v_err;
  end if;

  -- 5. Đường dẫn của đơn khác -------------------------------------------------
  begin
    perform public.attach_transfer_proof('PY-THUCK01', v_user::text || '/PY-THUCK02-1.jpg', '');
    v_err := '(không báo lỗi gì)';
  exception when others then
    v_err := sqlerrm;
  end;
  raise notice '5. gắn đường dẫn của đơn khác — máy chủ trả: %', v_err;
  if v_err <> 'path_invalid' then
    raise exception 'SAI 5: đợi ''path_invalid'', nhận ''%''.', v_err;
  end if;

  -- 6. Tệp chưa có trong kho --------------------------------------------------
  begin
    perform public.attach_transfer_proof('PY-THUCK01', v_user::text || '/PY-THUCK01-2.jpg', '');
    v_err := '(không báo lỗi gì)';
  exception when others then
    v_err := sqlerrm;
  end;
  raise notice '6. gắn tệp chưa tải lên — máy chủ trả: %', v_err;
  if v_err <> 'file_missing' then
    raise exception 'SAI 6: đợi ''file_missing'', nhận ''%''.', v_err;
  end if;

  reset role;
  raise notice 'SÁU ĐIỀU ĐỀU ĐÚNG. Giờ ném lỗi để quay đầu, không để lại gì.';
  raise exception 'QUAY_DAU_THEO_Y_DINH';
end
$do$;
