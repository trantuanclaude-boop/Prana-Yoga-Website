-- ============================================================================
-- SOÁT ĐƯỜNG ĐI CỦA SỐ LIỆU: TRANG CHỦ → SỔ ĐẾM → ĐIỂM SỨC KHOẺ — RỒI DỌN
--
-- Tệp này KHÔNG dựng gì. Trước khi chạy nó, trang chủ bản mới đã được mở
-- trong một trình duyệt thử với mã khách cố định 'vkiemtramuxyc6t1' và đã ghi
-- thật vài dòng vào public.site_events (máy chủ trả 201).
--
--   1. In ra những dòng ấy: loại việc, nguồn khách, giờ ghi.
--   2. Gọi public.admin_brand_health cho hôm nay, đúng vai người quản trị,
--      để thấy số người ghé / quan tâm có tính cả mã khách thử.
--   3. Xoá đúng những dòng của mã khách thử — số liệu thật không bị đụng tới.
--
-- Chạy trọn một giao dịch: bước nào hỏng thì không xoá gì cả.
-- ============================================================================
do $do$
declare
  v_vis     text := 'vkiemtramuxyc6t1';
  v_founder uuid;
  v_row     record;
  v_n       integer;
  r         jsonb;
  r_without jsonb;
begin
  select count(*) into v_n from public.site_events where visitor = v_vis;
  raise notice '1. Dòng của khách thử: %', v_n;
  if v_n = 0 then raise exception 'Không thấy dòng nào của khách thử — trang chủ chưa ghi được.'; end if;
  for v_row in select kind, item_key, source, created_at from public.site_events
               where visitor = v_vis order by created_at loop
    raise notice '   % | % | % | %', v_row.created_at, v_row.kind, v_row.item_key, v_row.source;
  end loop;

  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  r := public.admin_brand_health(date_trunc('day', now()) - interval '1 day', now(), false);
  raise notice '2. Hôm qua tới giờ — traffic: %', r->'traffic';
  raise notice '   interest: %', r->'interest';
  raise notice '   v2_since: %', r->'range'->>'v2_since';
  reset role;

  delete from public.site_events where visitor = v_vis;
  get diagnostics v_n = row_count;
  raise notice '3. Đã xoá % dòng thử.', v_n;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  r_without := public.admin_brand_health(date_trunc('day', now()) - interval '1 day', now(), false);
  raise notice '   Sau khi xoá — người ghé: % (trước đó %)', r_without->'traffic'->>'visitors', r->'traffic'->>'visitors';
  reset role;
end;
$do$;
