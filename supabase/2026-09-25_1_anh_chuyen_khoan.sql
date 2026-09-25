-- ============================================================================
-- ẢNH XÁC NHẬN CHUYỂN KHOẢN
--
-- Người trả bằng chuyển khoản QR hoặc chuyển khoản ngân hàng phải gửi kèm một
-- ảnh chụp màn hình giao dịch đã thành công. Trước đây studio chỉ có mã nội
-- dung chuyển khoản để đối soát, mà mã ấy sinh ở trình duyệt và không đi theo
-- đơn về máy chủ — khách ghi sai là không lần ra được khoản tiền nào của ai.
--
--   public.orders           — thêm ảnh đã gửi, lúc gửi, và nội dung chuyển
--                             khoản trang đã dặn khách ghi
--   public.payment_settings — câu dặn "phải gửi ảnh", sửa ở trang quản trị
--   kho 'chuyen-khoan'      — riêng tư; mỗi người chỉ ghi được vào thư mục
--                             của mình, và chỉ cho đơn chuyển khoản của mình
--   attach_transfer_proof   — gắn ảnh vừa tải lên vào đơn
--
-- Thứ tự ở trang: ghi đơn trước (place_order / purchase), rồi mới tải ảnh lên
-- và gắn vào. Nhờ vậy kho chỉ nhận ảnh của đơn đã có thật, và tải ảnh hỏng thì
-- đơn vẫn còn đó, khách gửi lại được ngay ở bước hoàn tất.
--
-- Chỉ thêm, không sửa hay xoá gì đã có. Chạy lại nhiều lần vẫn an toàn.
-- Chạy sau 2026-09-16_3_dat_don_hang_cua_hang.sql.
-- ============================================================================

-- 1. Sổ đơn giữ ảnh chuyển khoản ---------------------------------------------
-- transfer_proof là đường dẫn trong kho 'chuyen-khoan', trống = chưa gửi.
-- Gửi lại thì ảnh mới đè lên đường dẫn cũ; tệp cũ vẫn nằm trong kho.
alter table public.orders add column if not exists transfer_proof text not null default '';
alter table public.orders add column if not exists transfer_proof_at timestamptz;
alter table public.orders add column if not exists transfer_ref text not null default '';
alter table public.orders drop constraint if exists orders_transfer_proof_len;
alter table public.orders add constraint orders_transfer_proof_len
  check (char_length(transfer_proof) <= 300);
alter table public.orders drop constraint if exists orders_transfer_ref_len;
alter table public.orders add constraint orders_transfer_ref_len
  check (char_length(transfer_ref) <= 60);

-- 2. Câu dặn khách, sửa được ở trang quản trị --------------------------------
alter table public.payment_settings add column if not exists proof_note text not null
  default 'Sau khi chuyển khoản, bạn chụp màn hình giao dịch thành công — thấy rõ số tiền, thời gian và nội dung chuyển khoản — rồi gửi ảnh lên đây. Studio chỉ xác nhận đơn khi đã nhận được ảnh này.';
alter table public.payment_settings add column if not exists proof_note_en text default '';

-- 3. Ai được tải ảnh vào đâu --------------------------------------------------
-- Tên tệp phải là "<mã người dùng>/<mã đơn>-<số bất kỳ>.jpg", và đơn ấy phải là
-- đơn chuyển khoản của chính người đang tải. Không có đơn thì không có chỗ để
-- ảnh — kho không thành chỗ chứa đồ tuỳ ý của bất kỳ ai đăng nhập.
create or replace function public.can_send_transfer_proof(p_name text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(p_name, '') ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+$'
     and exists (
       select 1
       from public.orders o
       where o.user_id = (select auth.uid())
         and o.method in ('qr', 'bank')
         and starts_with(p_name, (select auth.uid())::text || '/' || o.code || '-')
     );
$function$;
revoke all on function public.can_send_transfer_proof(text) from public, anon;
grant execute on function public.can_send_transfer_proof(text) to authenticated;

-- 4. Kho ảnh riêng tư ---------------------------------------------------------
-- 10 MB mỗi tệp: trang đã thu ảnh về cỡ ~2000px trước khi gửi, nhưng máy nào
-- không thu được (trình duyệt cũ) thì ảnh chụp gốc vẫn lọt.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chuyen-khoan', 'chuyen-khoan', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Khách chỉ thêm được ảnh mới, không sửa hay xoá — ảnh là chứng từ tiền bạc.
drop policy if exists "Khách gửi ảnh chuyển khoản của đơn mình" on storage.objects;
create policy "Khách gửi ảnh chuyển khoản của đơn mình" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'chuyen-khoan' and public.can_send_transfer_proof(name));

drop policy if exists "Khách xem ảnh chuyển khoản của mình" on storage.objects;
create policy "Khách xem ảnh chuyển khoản của mình" on storage.objects
  for select to authenticated
  using (bucket_id = 'chuyen-khoan'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Quản trị xem và dọn ảnh chuyển khoản" on storage.objects;
create policy "Quản trị xem và dọn ảnh chuyển khoản" on storage.objects
  for all to authenticated
  using (bucket_id = 'chuyen-khoan' and public.is_admin())
  with check (bucket_id = 'chuyen-khoan' and public.is_admin());

-- 5. Gắn ảnh vào đơn ----------------------------------------------------------
-- Khách không sửa thẳng được bảng orders (mọi con số tiền phải giữ nguyên
-- như lúc máy chủ tính), nên đi qua hàm này: chỉ ba cột ảnh được chạm tới.
create or replace function public.attach_transfer_proof(
  p_code text,
  p_path text,
  p_ref text default ''::text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  v_code text := trim(coalesce(p_code, ''));
  v_path text := trim(coalesce(p_path, ''));
  v_ref text := left(trim(coalesce(p_ref, '')), 60);
  v_id uuid;
  v_method text;
begin
  if uid is null then
    raise exception 'not_signed_in';
  end if;

  select o.id, o.method into v_id, v_method
  from public.orders o
  where o.code = v_code and o.user_id = uid
  for update;
  if v_id is null then
    raise exception 'order_not_found';
  end if;
  if v_method not in ('qr', 'bank') then
    raise exception 'not_transfer';
  end if;

  if v_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+$'
     or not starts_with(v_path, uid::text || '/' || v_code || '-') then
    raise exception 'path_invalid';
  end if;
  if not exists (
    select 1 from storage.objects s
    where s.bucket_id = 'chuyen-khoan' and s.name = v_path
  ) then
    raise exception 'file_missing';
  end if;

  update public.orders
  set transfer_proof = v_path,
      transfer_proof_at = now(),
      transfer_ref = case when v_ref <> '' then v_ref else transfer_ref end
  where id = v_id;

  return jsonb_build_object('code', v_code, 'path', v_path, 'at', now());
end;
$function$;
revoke all on function public.attach_transfer_proof(text, text, text) from public, anon;
grant execute on function public.attach_transfer_proof(text, text, text) to authenticated;
