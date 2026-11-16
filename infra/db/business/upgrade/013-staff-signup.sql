-- 직원 가입 신청·총관리자 승인 (새 DB 는 08-staff-signup.sql 에 포함)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/013-staff-signup.sql
BEGIN;
CREATE TABLE IF NOT EXISTS staff_signups (
    signup_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid UNIQUE NOT NULL,                 -- Keycloak 계정 id (승인 전 비활성)
    username        text UNIQUE NOT NULL,
    name            text NOT NULL,
    email           text NOT NULL,
    requested_role  text NOT NULL CHECK (requested_role IN ('counselor', 'approver')),   -- 총관리자 가입 신청은 받지 않음
    created_at      timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, DELETE ON staff_signups TO app_user;

-- 승인: 승인자가 활성 총관리자인지 확인 → 직원 코드 발급(A-C03, A-P02 …) → users 등록 → 신청 삭제
DROP FUNCTION IF EXISTS approve_staff_signup(uuid, uuid);
CREATE FUNCTION approve_staff_signup(p_signup uuid, p_by uuid)
RETURNS TABLE (user_id uuid, pseudo_id text, role text, username text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s staff_signups%ROWTYPE; v_letter text; v_last int; v_next int; v_code text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users u WHERE u.user_id = p_by AND u.role = 'data_admin' AND u.active) THEN
        RAISE EXCEPTION 'approver must be active data_admin';
    END IF;
    SELECT * INTO s FROM staff_signups x WHERE x.signup_id = p_signup FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'signup not found';
    END IF;
    v_letter := CASE s.requested_role WHEN 'counselor' THEN 'C' ELSE 'P' END;
    -- 코드 순번: A-C01 … A-C99 다음 B-C01
    SELECT coalesce(max((ascii(left(u.pseudo_id, 1)) - 65) * 99 + substr(u.pseudo_id, 4, 2)::int), 0) INTO v_last
      FROM users u WHERE u.pseudo_id ~ ('^[A-Z]-' || v_letter || '[0-9]{2}$');
    v_next := v_last + 1;
    IF v_next > 26 * 99 THEN
        RAISE EXCEPTION 'staff code exhausted';
    END IF;
    v_code := chr(65 + (v_next - 1) / 99) || '-' || v_letter || lpad((((v_next - 1) % 99) + 1)::text, 2, '0');
    INSERT INTO users (user_id, pseudo_id, display_name, role) VALUES (s.user_id, v_code, s.username, s.requested_role);
    DELETE FROM staff_signups x WHERE x.signup_id = p_signup;
    RETURN QUERY SELECT s.user_id, v_code, s.requested_role, s.username;
END $$;
REVOKE ALL ON FUNCTION approve_staff_signup(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION approve_staff_signup(uuid, uuid) TO app_user;
COMMIT;
