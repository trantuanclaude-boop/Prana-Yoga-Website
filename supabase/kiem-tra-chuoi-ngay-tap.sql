-- ============================================================================
-- SOÁT LẠI CHUỖI NGÀY TẬP — CHẠY THỬ RỒI QUAY ĐẦU
--
-- Tệp này KHÔNG phải một bước dựng cơ sở dữ liệu. Nó nạp
-- 2026-10-17_1_chuoi_ngay_tap.sql vào cùng một giao dịch, tạo hai khách thử,
-- thử mọi đường được và bị chặn, rồi tự ném lỗi ở dòng cuối để cả giao dịch
-- quay về như cũ. Lần chạy BÁO ĐỎ với QUAY_DAU_THEO_Y_DINH mới là đúng.
--
-- Soát chín điều:
--   1. Khách vãng lai đọc được luật, không đọc được ngày tập của ai.
--   2. Bài đang khoá thì phòng học không ghi được phút.
--   3. Bài học thử: ghi phút, ghi bài xong, bấm xong hai lần không đếm hai.
--   4. Tự tập: ghi được hôm nay; studio tắt thì bị chặn.
--   5. Khách B không thấy ngày tập của khách A.
--   6. Khách không sửa được luật, không gọi được hàm quản trị.
--   7. Quản trị điểm danh ngày hôm qua, xoá một ngày về trống thì dòng biến mất,
--      ngày mai thì bị chặn.
--   8. Tóm tắt: chuỗi hiện tại / dài nhất đúng luật, kể cả ngày nghỉ.
--   9. Luật sửa được bởi quản trị; mốc tự xếp, bỏ trùng.
-- ============================================================================
\ir 2026-10-17_1_chuoi_ngay_tap.sql

do $do$
declare
  v_a       uuid;
  v_b       uuid;
  v_founder uuid;
  v_course  text;
  v_idx     smallint;
  v_lock    text;
  v_lidx    smallint;
  v_today   date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_j       jsonb;
  v_n       integer;
  v_err     text;
  r         record;
begin
  select s.user_id into v_founder from public.staff s order by (s.role = 'founder') desc limit 1;
  if v_founder is null then raise exception 'SAI: không có ai trong public.staff để thử.'; end if;

  select l.course_key, l.idx into v_course, v_idx
  from public.course_lessons l where l.is_free order by l.course_key, l.idx limit 1;
  select l.course_key, l.idx into v_lock, v_lidx
  from public.course_lessons l where not l.is_free order by l.course_key, l.idx limit 1;
  if v_course is null or v_lock is null then raise exception 'SAI: không có bài học thử / bài khoá để thử.'; end if;

  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-chuoi-a@vidu.test') returning id into v_a;
  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', 'thu-chuoi-b@vidu.test') returning id into v_b;
  raise notice 'Khách A %, khách B %, quản trị %, bài thử %:%, bài khoá %:%', v_a, v_b, v_founder, v_course, v_idx, v_lock, v_lidx;

  -- 1. Vãng lai ------------------------------------------------------------------
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select count(*) into v_n from public.streak_settings;
  raise notice '1a. vãng lai đọc luật: % dòng', v_n;
  if v_n <> 1 then raise exception 'SAI 1a: vãng lai không đọc được luật.'; end if;
  begin
    select count(*) into v_n from public.study_days;
    v_err := '(không bị chặn, đọc được ' || v_n || ' dòng)';
  exception when insufficient_privilege then v_err := 'bị chặn';
  end;
  raise notice '1b. vãng lai đọc ngày tập: %', v_err;
  if v_err <> 'bị chặn' then raise exception 'SAI 1b: vãng lai đọc được ngày tập.'; end if;
  begin
    perform public.study_ping(v_course, v_idx, 60, false);
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '1c. vãng lai gọi study_ping: %', v_err;
  if v_err = '(không bị chặn)' then raise exception 'SAI 1c: vãng lai ghi được phút tập.'; end if;
  reset role;

  -- 2 + 3. Khách A trong phòng học --------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    perform public.study_ping(v_lock, v_lidx, 60, false);
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '2. bài khoá: %', v_err;
  if v_err <> 'lesson_locked' then raise exception 'SAI 2: ghi được phút cho bài chưa mở.'; end if;

  v_j := public.study_ping(v_course, v_idx, 60, false);
  v_j := public.study_ping(v_course, v_idx, 999, false);       -- trần 180 giây mỗi lần
  v_j := public.study_ping(v_course, v_idx, 0, true);
  v_j := public.study_ping(v_course, v_idx, 0, true);          -- bấm xong lần hai
  raise notice '3. sau bốn lần gửi: %', v_j;
  if (v_j->>'online_sec')::int <> 240 then raise exception 'SAI 3a: giây học là %, mong 240.', v_j->>'online_sec'; end if;
  if jsonb_array_length(v_j->'lessons') <> 1 then raise exception 'SAI 3b: một bài xong mà đếm % lần.', jsonb_array_length(v_j->'lessons'); end if;
  if (v_j->>'day')::date <> v_today then raise exception 'SAI 3c: ngày ghi là %, mong %.', v_j->>'day', v_today; end if;

  -- 4. Tự tập ------------------------------------------------------------------------
  v_j := public.study_self(30);
  raise notice '4a. tự tập 30 phút: self_min = %', v_j->>'self_min';
  if (v_j->>'self_min')::int <> 30 then raise exception 'SAI 4a: không ghi được phút tự tập.'; end if;
  v_j := public.study_self(500);
  if (v_j->>'self_min')::int <> 240 then raise exception 'SAI 4b: tự tập vượt trần 240 phút.'; end if;
  v_j := public.study_self(30);

  -- 6. Khách đụng vào việc của quản trị ----------------------------------------------
  update public.streak_settings set goal_minutes = 1 where id = 1;
  get diagnostics v_n = row_count;
  raise notice '6a. khách sửa luật: % dòng đổi', v_n;
  if v_n <> 0 then raise exception 'SAI 6a: khách sửa được luật chuỗi.'; end if;
  begin
    perform public.admin_study_set(v_a, v_today, 0, 600, 'tự điểm danh');
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '6b. khách gọi admin_study_set: %', v_err;
  if v_err <> 'not_admin' then raise exception 'SAI 6b: khách tự điểm danh được.'; end if;
  select count(*) into v_n from public.admin_study_overview('', 50);
  raise notice '6c. khách gọi admin_study_overview: % dòng', v_n;
  if v_n <> 0 then raise exception 'SAI 6c: khách xem được danh sách chuỗi.'; end if;
  begin
    perform * from private.study_summary(v_a);
    v_err := '(không bị chặn)';
  exception when others then v_err := 'bị chặn';
  end;
  if v_err <> 'bị chặn' then raise exception 'SAI 6d: khách gọi thẳng được private.study_summary.'; end if;
  reset role;

  -- 5. Khách B -----------------------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.study_days where user_id = v_a;
  raise notice '5. khách B thấy ngày tập của A: % dòng', v_n;
  if v_n <> 0 then raise exception 'SAI 5: khách B đọc được ngày tập của A.'; end if;
  reset role;

  -- 7. Quản trị điểm danh ---------------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_founder, 'role', 'authenticated')::text, true);
  v_j := public.admin_study_set(v_a, v_today - 1, 0, 60, 'Hatha sáng');
  raise notice '7a. điểm danh hôm qua: %', v_j;
  if (v_j->>'studio_min')::int <> 60 or v_j->>'staff_note' <> 'Hatha sáng' then raise exception 'SAI 7a: điểm danh không ghi.'; end if;
  perform public.admin_study_set(v_a, v_today - 3, 0, 60, '');
  perform public.admin_study_set(v_a, v_today - 2, 0, 45, '');
  perform public.admin_study_set(v_a, v_today - 2, 0, 0, '');          -- xoá về trống
  select count(*) into v_n from public.study_days where user_id = v_a and day = v_today - 2;
  raise notice '7b. ngày xoá về trống còn % dòng', v_n;
  if v_n <> 0 then raise exception 'SAI 7b: ngày trống vẫn còn dòng.'; end if;
  begin
    perform public.admin_study_set(v_a, v_today + 1, 0, 60, '');
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '7c. điểm danh ngày mai: %', v_err;
  if v_err <> 'day_invalid' then raise exception 'SAI 7c: điểm danh được ngày chưa tới.'; end if;

  -- 8. Tóm tắt ---------------------------------------------------------------------------
  -- A: hôm nay (online + tự tập), hôm qua (studio), hôm kia trống, ba hôm trước (studio)
  select * into r from public.admin_study_overview('thu-chuoi-a@vidu.test', 10);
  raise notice '8a. A: chuỗi % · dài nhất % · 30 ngày % ngày / % phút · hôm nay % phút',
    r.cur_streak, r.best_streak, r.days_30, r.min_30, r.today_min;
  if r.cur_streak <> 2 or r.best_streak <> 2 then raise exception 'SAI 8a: chuỗi % / %, mong 2 / 2.', r.cur_streak, r.best_streak; end if;
  if r.today_min <> 34 then raise exception 'SAI 8b: hôm nay % phút, mong 34 (4 online + 30 tự tập).', r.today_min; end if;
  select count(*) into v_n from public.admin_study_overview('', 500) o where o.user_id = v_b;
  if v_n <> 0 then raise exception 'SAI 8c: ô tìm trống mà hiện cả người chưa tập.'; end if;

  -- 9. Luật: hôm kia là ngày nghỉ → chuỗi nối qua, mốc tự xếp
  update public.streak_settings
     set rest_days = array[extract(isodow from v_today - 2)::smallint, extract(isodow from v_today - 2)::smallint],
         milestones = '{21,7,7,3}'
   where id = 1;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'SAI 9a: quản trị không sửa được luật.'; end if;
  select * into r from public.admin_study_overview('thu-chuoi-a@vidu.test', 10);
  raise notice '9b. hôm kia thành ngày nghỉ: chuỗi % · dài nhất %', r.cur_streak, r.best_streak;
  if r.cur_streak <> 3 then raise exception 'SAI 9b: ngày nghỉ vẫn làm đứt chuỗi (% ngày).', r.cur_streak; end if;
  select s.milestones::text || ' ' || s.rest_days::text || ' ' || coalesce(s.updated_by::text, '?') into v_err
  from public.streak_settings s where s.id = 1;
  raise notice '9c. mốc · ngày nghỉ · người sửa: %', v_err;
  if v_err not like '{3,7,21} {%} ' || v_founder::text then raise exception 'SAI 9c: mốc/ngày nghỉ chưa xếp gọn hoặc thiếu người sửa.'; end if;

  -- 4c. Tắt tự tập rồi để khách thử
  update public.streak_settings set allow_self = false where id = 1;
  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    perform public.study_self(15);
    v_err := '(không bị chặn)';
  exception when others then v_err := sqlerrm;
  end;
  raise notice '4c. studio tắt tự tập: %', v_err;
  if v_err <> 'self_off' then raise exception 'SAI 4c: tự tập vẫn ghi khi studio đã tắt.'; end if;
  select count(*) into v_n from public.study_days where user_id = v_a;
  raise notice '4d. A đọc ngày tập của mình: % dòng', v_n;
  if v_n <> 3 then raise exception 'SAI 4d: A thấy % dòng, mong 3.', v_n; end if;
  reset role;

  raise notice 'Qua cả chín điều.';
  raise exception 'QUAY_DAU_THEO_Y_DINH';
end;
$do$;
