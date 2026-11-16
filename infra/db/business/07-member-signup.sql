-- 이음 자체 회원가입 (internal-api /api/internal/member-signups 에서만 호출)
-- app_user 는 users·members INSERT 권한이 없다. 가입은 이 함수로만 만든다 (회원 역할·활성 상태 고정).
-- 기존 DB 는 upgrade/012-member-signup.sql 로 같은 내용을 적용한다.
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
