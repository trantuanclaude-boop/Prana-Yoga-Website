-- ============================================================================
-- SỨC KHOẺ THƯƠNG HIỆU
--
-- Trang quản trị có thêm mục "Sức khoẻ thương hiệu": chấm sáu thành phần —
-- nhận biết, sức hút, chuyển thành khách mua, gắn bó, hài lòng, phục vụ — rồi
-- gộp thành một điểm trên thang 10. Muốn chấm được thì phải biết khách làm gì
-- ngoài chuyện mua: họ từ đâu tới, ở lại bao lâu, xem món gì, có bỏ vào giỏ,
-- có hỏi tư vấn không. File này làm ba việc:
--
--   1. public.site_events nhận thêm năm loại việc và một cột source (khách từ
--      đâu tới). Vẫn không có tên, email hay IP — chỉ mã ngẫu nhiên của trình
--      duyệt như từ 2026-09-16.
--   2. public.admin_brand_health(từ, tới, tính_cả_quản_trị) gom sổ ấy với đơn
--      hàng, đăng ký học, tiến độ, đánh giá, đặt lịch thành các con số thô cho
--      một quãng thời gian. Chấm điểm thì trang quản trị làm, để mốc chấm sửa
--      được mà không phải chạy lại SQL. Chỉ quản trị gọi được.
--   3. public.admin_funnel đếm "Quan tâm" bằng đủ các loại việc mới.
--
-- Mặc định KHÔNG tính người trong public.staff: đơn thử, lượt ghé thử của
-- chủ studio không phải hành vi của khách. Trình duyệt nào từng đăng nhập
-- bằng tài khoản quản trị thì mọi lượt của trình duyệt ấy cũng bị loại.
--
-- Chạy sau 2026-09-27_2_mau_lich_cho_hoc_vien.sql. Chạy lại nhiều lần vẫn an
-- toàn: chỉ thêm cột, đổi điều kiện và thay hàm.
-- ============================================================================

-- 1. Sổ ghi lượt: thêm loại việc và nguồn khách ------------------------------
-- kind:    'visit'    — mở trang (một lần mỗi ngày mỗi trình duyệt)
--          'stay'     — ở lại quá 45 giây với thẻ đang mở trên màn hình
--          'course'   — mở trang chi tiết một khoá học
--          'product'  — mở xem một món hàng
--          'pricing'  — kéo tới bảng giá gói cộng đồng
--          'cart'     — bỏ một món vào giỏ
--          'checkout' — vào tới bước trả tiền (khoá, gói, hoặc 'shop')
--          'chat'     — gửi câu hỏi cho khung tư vấn
-- source:  chỉ dòng 'visit' mới ghi. 'direct', 'search:google',
--          'social:facebook', 'ads:google', 'email:…', 'ref:<tên miền>'.
--          Dòng cũ trước file này để trống.
alter table public.site_events drop constraint if exists site_events_kind_check;
alter table public.site_events add constraint site_events_kind_check
  check (kind in ('visit', 'stay', 'course', 'product', 'pricing', 'cart', 'checkout', 'chat'));

alter table public.site_events add column if not exists source text not null default '';
alter table public.site_events drop constraint if exists site_events_source_check;
alter table public.site_events add constraint site_events_source_check
  check (char_length(source) <= 60);

comment on column public.site_events.source is
  'Khách từ đâu tới, chỉ ghi ở dòng visit: direct, search:<máy tìm>, social:<mạng>, ads:<nguồn>, email:<nguồn>, ref:<tên miền>.';

-- Quyền ghi giữ nguyên: anon và authenticated chỉ insert, không ai select.

-- 2. Số liệu thô cho mục Sức khoẻ thương hiệu --------------------------------
-- Trả một jsonb năm nhóm: traffic, interest, conversion, loyalty, satisfaction,
-- service. Số "trong kỳ" lấy đúng [p_from, p_to); số "tích luỹ" (khách mua
-- lại, đánh giá, hoàn tiền) lấy mọi thứ trước p_to, vì một studio nhỏ có quá
-- ít đơn trong một tháng để đọc ra tỷ lệ mua lại. Nhóm service là chuyện của
-- lúc này (đơn đang chờ, lịch chưa gọi lại), không theo kỳ.
create or replace function public.admin_brand_health(
  p_from timestamptz,
  p_to timestamptz,
  p_with_staff boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_staff uuid[];
  v_svis text[];
  v_v2 timestamptz;
  r jsonb;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'range_invalid';
  end if;

  v_staff := case when coalesce(p_with_staff, false) then '{}'::uuid[]
                  else array(select s.user_id from public.staff s) end;
  -- Trình duyệt từng gắn với tài khoản quản trị: loại cả những lượt nó ghi
  -- trước lúc đăng nhập.
  v_svis := array(select distinct e.visitor from public.site_events e
                  where e.user_id = any(v_staff));
  -- Mốc sổ đếm bản mới bắt đầu ghi: dòng visit đầu tiên có nguồn khách.
  select min(e.created_at) into v_v2 from public.site_events e where e.source <> '';

  with ev as (
    select e.visitor, e.user_id, e.kind, e.item_key, e.source, e.created_at
    from public.site_events e
    where e.created_at >= p_from and e.created_at < p_to
      and not (e.visitor = any(v_svis))
  ),
  ord as (
    select o.id, o.user_id, coalesce(o.user_id::text, lower(o.buyer_email)) as who,
           o.kind, o.item_key, o.status, o.total_vnd, o.created_at
    from public.orders o
    where o.user_id is null or not (o.user_id = any(v_staff))
  ),
  first_visit as (
    select distinct on (ev.visitor) ev.visitor, ev.source
    from ev where ev.kind = 'visit'
    order by ev.visitor, ev.created_at
  )
  select jsonb_build_object(
    'range', jsonb_build_object('from', p_from, 'to', p_to, 'now', now(),
      'v2_since', v_v2,
      'first_event', (select min(e.created_at) from public.site_events e),
      'with_staff', coalesce(p_with_staff, false)),

    'traffic', jsonb_build_object(
      'visitors', (select count(distinct ev.visitor) from ev),
      'visits', (select count(*) from ev where ev.kind = 'visit'),
      'visitors_v2', (select count(distinct ev.visitor) from ev
                      where v_v2 is not null and ev.created_at >= v_v2),
      'returning', (select count(*) from (
          select ev.visitor from ev group by ev.visitor
          having count(distinct (ev.created_at at time zone 'Asia/Ho_Chi_Minh')::date) >= 2) x),
      'new_visitors', (select count(distinct ev.visitor) from ev
          where not exists (select 1 from public.site_events e2
                            where e2.visitor = ev.visitor and e2.created_at < p_from)),
      'sources', (select coalesce(jsonb_object_agg(s.cat, s.n), '{}'::jsonb) from (
          select coalesce(nullif(split_part(f.source, ':', 1), ''), 'unknown') as cat, count(*) as n
          from first_visit f group by 1) s),
      'source_top', (select coalesce(jsonb_agg(jsonb_build_object('s', t.s, 'n', t.n) order by t.n desc), '[]'::jsonb) from (
          select f.source as s, count(*) as n from first_visit f
          where f.source <> '' group by 1 order by 2 desc limit 8) t)
    ),

    'interest', (select jsonb_build_object(
        'stayed', count(distinct ev.visitor) filter (where ev.kind = 'stay'),
        'course', count(distinct ev.visitor) filter (where ev.kind = 'course'),
        'product', count(distinct ev.visitor) filter (where ev.kind = 'product'),
        'pricing', count(distinct ev.visitor) filter (where ev.kind = 'pricing'),
        'cart', count(distinct ev.visitor) filter (where ev.kind = 'cart'),
        'checkout', count(distinct ev.visitor) filter (where ev.kind = 'checkout'),
        'chat', count(distinct ev.visitor) filter (where ev.kind = 'chat'),
        'interested', count(distinct ev.visitor) filter (
            where ev.kind in ('course', 'product', 'pricing', 'cart', 'checkout', 'chat')),
        'views', count(*) filter (where ev.kind in ('course', 'product'))
      ) from ev),

    'top_items', (select coalesce(jsonb_agg(jsonb_build_object(
          'kind', t.kind, 'key', t.item_key, 'viewers', t.n,
          'name', case when t.kind = 'product'
                       then (select p.name from public.products p where p.key = t.item_key)
                       else (select c.name from public.courses c where c.key = t.item_key) end,
          'orders', case when t.kind = 'product'
                         then (select count(distinct o.id) from ord o
                               join public.order_items i on i.order_id = o.id
                               where i.product_key = t.item_key and o.status = 'paid'
                                 and o.created_at >= p_from and o.created_at < p_to)
                         else (select count(*) from ord o
                               where o.item_key = t.item_key and o.status = 'paid'
                                 and o.created_at >= p_from and o.created_at < p_to) end
        ) order by t.n desc), '[]'::jsonb) from (
          select ev.kind, ev.item_key, count(distinct ev.visitor) as n from ev
          where ev.kind in ('course', 'product') and ev.item_key <> ''
          group by 1, 2 order by 3 desc limit 6) t),

    'conversion', (select jsonb_build_object(
        'paid', count(*) filter (where o.status = 'paid'),
        'pending', count(*) filter (where o.status = 'pending'),
        'stale', count(*) filter (where o.status = 'pending' and o.created_at < now() - interval '72 hours'),
        'cancelled', count(*) filter (where o.status = 'cancelled'),
        'refunded', count(*) filter (where o.status = 'refunded'),
        'revenue', coalesce(sum(o.total_vnd) filter (where o.status = 'paid'), 0),
        'buyers', count(distinct o.who) filter (where o.status = 'paid'),
        'registered', (select count(*) from public.profiles p
                       where p.created_at >= p_from and p.created_at < p_to
                         and not (p.id = any(v_staff))),
        'checkout_ordered', (select count(distinct c.visitor) from ev c
            where c.kind = 'checkout'
              and exists (select 1 from public.site_events e2
                          join ord o2 on o2.user_id = e2.user_id
                          where e2.visitor = c.visitor
                            and o2.created_at >= p_from and o2.created_at < p_to)),
        'bookings', (select count(*) from public.bookings b
                     where b.created_at >= p_from and b.created_at < p_to
                       and (b.user_id is null or not (b.user_id = any(v_staff)))),
        'bookings_done', (select count(*) from public.bookings b
                          where b.created_at >= p_from and b.created_at < p_to and b.status <> 'new'
                            and (b.user_id is null or not (b.user_id = any(v_staff))))
      ) from ord o where o.created_at >= p_from and o.created_at < p_to),

    'loyalty', jsonb_build_object(
      'buyers_all', (select count(*) from (
          select o.who from ord o where o.status = 'paid' and o.created_at < p_to group by 1) b),
      'repeat_all', (select count(*) from (
          select o.who from ord o where o.status = 'paid' and o.created_at < p_to
          group by 1 having count(*) >= 2) b),
      'returning_buyers', (select count(distinct o.who) from ord o
          where o.status = 'paid' and o.created_at >= p_from and o.created_at < p_to
            and exists (select 1 from ord o2 where o2.who = o.who and o2.status = 'paid'
                        and o2.created_at < p_from)),
      'subs_due', (select count(*) from public.member_subscriptions s
          where s.ends_at >= p_from and s.ends_at < least(p_to, now())
            and not (s.user_id = any(v_staff))),
      'subs_renewed', (select count(*) from public.member_subscriptions s
          where s.ends_at >= p_from and s.ends_at < least(p_to, now())
            and not (s.user_id = any(v_staff))
            and exists (select 1 from public.member_subscriptions s2
                        where s2.user_id = s.user_id and s2.id <> s.id
                          and s2.created_at > s.created_at)),
      'members_active', (select count(distinct s.user_id) from public.member_subscriptions s
          where s.starts_at < p_to and s.ends_at >= p_to and not (s.user_id = any(v_staff))),
      'enrolled', (select count(distinct ce.user_id) from public.course_enrollments ce
          where ce.created_at < p_to and not (ce.user_id = any(v_staff))),
      'learning', (select count(distinct ce.user_id) from public.course_enrollments ce
          where ce.created_at < p_to and not (ce.user_id = any(v_staff))
            and exists (select 1 from public.course_progress g
                        where g.user_id = ce.user_id
                          and g.updated_at >= p_from and g.updated_at < p_to)),
      'completion', (select jsonb_build_object('n', count(*),
            'avg', avg(least(1.0, coalesce(cardinality(g.done), 0)::numeric / l.n)))
          from (select distinct ce.user_id, ce.course_key from public.course_enrollments ce
                where ce.access = 'full' and ce.created_at < p_to
                  and not (ce.user_id = any(v_staff))) x
          join (select cl.course_key, count(*) as n from public.course_lessons cl group by 1) l
            on l.course_key = x.course_key
          left join public.course_progress g
            on g.user_id = x.user_id and g.course_key = x.course_key)
    ),

    'satisfaction', (select jsonb_build_object(
        'reviews', count(*),
        'stars', coalesce(sum(rv.rating), 0),
        'low', count(*) filter (where rv.rating <= 3),
        'hidden', count(*) filter (where rv.is_hidden),
        'new', count(*) filter (where rv.created_at >= p_from),
        'reviewers', count(distinct rv.user_id),
        'honor', (select count(*) from public.honor_roll h where h.is_published and not h.is_sample),
        'paid_all', (select count(*) from ord o where o.status = 'paid' and o.created_at < p_to),
        'refunded_all', (select count(*) from ord o where o.status = 'refunded' and o.created_at < p_to)
      ) from (
        select cr.user_id, cr.rating, cr.is_hidden, cr.created_at from public.course_reviews cr
        union all
        select pr.user_id, pr.rating, pr.is_hidden, pr.created_at from public.product_reviews pr
      ) rv
      where rv.created_at < p_to and not (rv.user_id = any(v_staff))),

    'service', jsonb_build_object(
      'pending_now', (select count(*) from ord o where o.status = 'pending'),
      'pending_late', (select count(*) from ord o
          where o.status = 'pending' and o.created_at < now() - interval '24 hours'),
      'pending_oldest_h', (select floor(extract(epoch from now() - min(o.created_at)) / 3600)
          from ord o where o.status = 'pending'),
      'book_new', (select count(*) from public.bookings b
          where b.status = 'new' and (b.user_id is null or not (b.user_id = any(v_staff)))),
      'book_late', (select count(*) from public.bookings b
          where b.status = 'new' and b.created_at < now() - interval '24 hours'
            and (b.user_id is null or not (b.user_id = any(v_staff)))),
      'courses_on', (select count(*) from public.courses c where c.is_active),
      'courses_img', (select count(*) from public.courses c where c.is_active and c.image_url <> ''),
      'courses_lessons', (select count(*) from public.courses c where c.is_active
          and exists (select 1 from public.course_lessons l where l.course_key = c.key)),
      'packs_on', (select count(*) from public.memberships m where m.is_active),
      'packs_sched', (select count(*) from public.memberships m where m.is_active
          and exists (select 1 from public.class_schedule s
                      where s.membership_key = m.key and s.is_active
                        and (s.end_date is null or s.end_date >= current_date)))
    )
  ) into r;

  return r;
end;
$function$;

revoke all on function public.admin_brand_health(timestamptz, timestamptz, boolean) from public, anon;
grant execute on function public.admin_brand_health(timestamptz, timestamptz, boolean) to authenticated;

comment on function public.admin_brand_health(timestamptz, timestamptz, boolean) is
  'Số liệu thô cho mục Sức khoẻ thương hiệu của trang quản trị. Chỉ quản trị gọi được; mặc định loại người trong public.staff.';

-- 3. Phễu ở Tổng quan: "Quan tâm" đếm đủ các loại việc mới -------------------
-- Giữ nguyên mọi bậc khác của 2026-09-16_1; chỉ bậc interested đổi danh sách
-- loại việc (thêm xem món hàng, bảng giá, giỏ hàng, hỏi tư vấn).
create or replace function public.admin_funnel(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'range_invalid';
  end if;

  select jsonb_build_object(
    'visits', (
      select count(*) from public.site_events e
      where e.kind = 'visit' and e.created_at >= p_from and e.created_at < p_to),
    'visitors', (
      select count(distinct e.visitor) from public.site_events e
      where e.created_at >= p_from and e.created_at < p_to),
    'interested', (
      select count(distinct e.visitor) from public.site_events e
      where e.kind in ('course', 'product', 'pricing', 'cart', 'checkout', 'chat')
        and e.created_at >= p_from and e.created_at < p_to),
    'checkout', (
      select count(distinct e.visitor) from public.site_events e
      where e.kind = 'checkout'
        and e.created_at >= p_from and e.created_at < p_to),
    'registered', (
      select count(*) from public.profiles p
      where p.created_at >= p_from and p.created_at < p_to),
    'buyers', (
      select count(distinct o.user_id) from public.orders o
      where o.status = 'paid' and o.created_at >= p_from and o.created_at < p_to),
    'learners', (
      select count(distinct g.user_id) from public.course_progress g
      where g.updated_at >= p_from and g.updated_at < p_to),
    'returning', (
      select count(distinct o.user_id) from public.orders o
      where o.status = 'paid' and o.created_at >= p_from and o.created_at < p_to
        and exists (
          select 1 from public.orders o2
          where o2.user_id = o.user_id and o2.status = 'paid'
            and o2.created_at < o.created_at))
  ) into r;
  return r;
end;
$function$;
revoke all on function public.admin_funnel(timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_funnel(timestamptz, timestamptz) to authenticated;
