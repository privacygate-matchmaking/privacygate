-- 회원가입: register_member() + 담당 회원이 가장 적은 상담 직원 배정 (새 DB 는 07-member-signup.sql 에 포함)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/012-member-signup.sql
BEGIN;
ALTER TABLE members ADD COLUMN IF NOT EXISTS privacy_consent_version text;     -- 가입 시 개인정보 수집·이용 동의 문구 버전
ALTER TABLE members ADD COLUMN IF NOT EXISTS privacy_consented_at timestamptz;

-- 담당자 자동 배정: 활성 상담 직원 중 담당 회원(탈퇴 대기 제외)이 가장 적은 사람. 같으면 무작위
CREATE OR REPLACE FUNCTION assign_random_counselor() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    WITH picked AS (
        INSERT INTO assignments (user_id, member_id)
        SELECT u.user_id, NEW.member_id
          FROM users u
         WHERE u.role = 'counselor' AND u.active
         ORDER BY (SELECT count(*) FROM assignments a JOIN members m ON m.member_id = a.member_id
                    WHERE a.user_id = u.user_id AND m.status = 'active'), random()
         LIMIT 1
        ON CONFLICT DO NOTHING
        RETURNING user_id
    )
    INSERT INTO notifications (user_id, kind, title, body, link_view)
    SELECT user_id, 'member_assigned', '새 담당 회원 배정', NEW.pseudo_id || ' ' || NEW.name || ' 회원이 배정되었습니다.', 'members'
      FROM picked;
    RETURN NEW;
END $$;

DROP FUNCTION IF EXISTS register_member(uuid, text, text, text, date, text, text, text, text, smallint, smallint, text, text);
CREATE FUNCTION register_member(p_user uuid, p_username text, p_name text, p_gender text, p_birth date,
                                p_phone text, p_email text, p_education text, p_job text,
                                p_height smallint, p_weight smallint, p_intro text, p_consent text)
RETURNS TABLE (member_id uuid, pseudo_id text, counselor_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text := next_member_code(); v_member uuid;
BEGIN
    IF p_consent IS NULL THEN
        RAISE EXCEPTION 'privacy consent required';
    END IF;
    INSERT INTO users (user_id, pseudo_id, display_name, role) VALUES (p_user, v_code, p_username, 'member');
    INSERT INTO members (user_id, pseudo_id, name, gender, birth_date, height_cm, weight_kg, education_level,
                         job_group, introduction, contact_phone, contact_email,
                         privacy_consent_version, privacy_consented_at)
    VALUES (p_user, v_code, p_name, p_gender, p_birth, p_height, p_weight, p_education,
            p_job, p_intro, p_phone, p_email, p_consent, now())
    RETURNING members.member_id INTO v_member;   -- 트리거가 담당 상담 직원을 배정한다
    RETURN QUERY SELECT v_member, v_code,
                        (SELECT a.user_id FROM assignments a WHERE a.member_id = v_member LIMIT 1);
END $$;
REVOKE ALL ON FUNCTION register_member(uuid, text, text, text, date, text, text, text, text, smallint, smallint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_member(uuid, text, text, text, date, text, text, text, text, smallint, smallint, text, text) TO app_user;
COMMIT;
