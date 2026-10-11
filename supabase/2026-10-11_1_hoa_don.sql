-- ============================================================================
-- HOÁ ĐƠN: NGÀY NHẬN TIỀN VÀ SỔ ĐỔI TRẠNG THÁI
--
-- Khách xem hoá đơn của mình ở Hồ sơ → Hoá đơn; chủ studio và những người
-- được cấp quyền quản trị (bảng public.staff) xem mọi hoá đơn ở trang quản
-- trị → Đơn hàng để đối chiếu với sao kê. Hoá đơn đọc thẳng bảng orders và
-- order_items như trước; tệp này chỉ thêm hai thứ hoá đơn còn thiếu:
--
--   orders.paid_at          — lúc đơn chuyển sang "đã thanh toán": thẻ / ví là
--                             lúc đặt, chuyển khoản là lúc studio bấm "Đã nhận
--                             tiền". Khách đọc được, in trên hoá đơn.
--   public.order_status_log — ai đổi trạng thái đơn nào, từ gì sang gì, lúc
--                             nào. Khách không đọc được: tên nhân viên không
--                             phải việc của khách.
--   admin_order_log(order)  — đọc sổ ấy kèm tên, email và bậc của người bấm.
--
-- Hai trigger trên orders lo cả hai việc, nên mọi đường đổi trạng thái — hàm
-- admin_set_order_status, SQL gõ tay, hàm viết sau này — đều được ghi lại.
--
-- Chỉ thêm, không sửa hay xoá gì đã có. Chạy lại nhiều lần vẫn an toàn.
-- Chạy sau 2026-09-25_4_anh_bat_buoc_va_cod.sql.
-- ============================================================================

-- 1. Ngày nhận tiền -------------------------------------------------------------
alter table public.orders add column if not exists paid_at timestamptz;

-- Đơn thẻ / ví đã trả tiền ngay lúc đặt, nên ngày đặt chính là ngày trả. Đơn
-- chuyển khoản duyệt trước hôm nay thì không còn biết studio bấm lúc nào — để
-- trống, hoá đơn không bịa ra một ngày.
update public.orders
set paid_at = created_at
where paid_at is null
  and method in ('card', 'wallet')
  and status in ('paid', 'refunded');

create or replace function private.orders_paid_at()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.status = 'paid'
     and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    new.paid_at := now();
  elsif new.status = 'pending' then
    -- Bấm nhầm "Đã nhận tiền" rồi trả về chờ: hoá đơn thôi ghi ngày đã trả
    new.paid_at := null;
  end if;
  -- Huỷ / hoàn tiền giữ nguyên ngày cũ: tiền đã từng vào thật
  return new;
end;
$function$;

drop trigger if exists orders_paid_at on public.orders;
create trigger orders_paid_at
  before insert or update of status on public.orders
  for each row execute function private.orders_paid_at();

-- 2. Sổ đổi trạng thái ----------------------------------------------------------
create table if not exists public.order_status_log (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders (id) on delete cascade,
  changed_at  timestamptz not null default now(),
  -- Người bấm. Tài khoản bị xoá thì còn lại dòng sổ, mất tên — đúng như luật
  -- dọn học viên cũ: không giữ dấu vết cá nhân của người đã đi.
  actor       uuid references auth.users (id) on delete set null,
  from_status text,
  to_status   text not null
);
create index if not exists order_status_log_order_idx
  on public.order_status_log (order_id, changed_at);

-- Không chính sách nào, không quyền nào: chỉ đọc qua admin_order_log
alter table public.order_status_log enable row level security;
revoke all on public.order_status_log from public, anon, authenticated;

create or replace function private.orders_log_status()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if old.status is not distinct from new.status then
    return null;
  end if;
  insert into public.order_status_log (order_id, actor, from_status, to_status)
  values (new.id, auth.uid(), old.status, new.status);
  return null;
end;
$function$;

drop trigger if exists orders_log_status on public.orders;
create trigger orders_log_status
  after update of status on public.orders
  for each row execute function private.orders_log_status();

-- 3. Quản trị đọc sổ --------------------------------------------------------------
create or replace function public.admin_order_log(p_order uuid)
returns table (
  changed_at  timestamptz,
  from_status text,
  to_status   text,
  by_name     text,
  by_email    text,
  by_role     text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  return query
  select l.changed_at, l.from_status, l.to_status,
         coalesce(p.full_name, '')::text,
         coalesce(u.email, '')::text,
         coalesce(s.role, '')::text
  from public.order_status_log l
  left join auth.users u on u.id = l.actor
  left join public.profiles p on p.id = l.actor
  left join public.staff s on s.user_id = l.actor
  where l.order_id = p_order
  order by l.changed_at, l.id;
end;
$function$;
revoke all on function public.admin_order_log(uuid) from public, anon;
grant execute on function public.admin_order_log(uuid) to authenticated;
