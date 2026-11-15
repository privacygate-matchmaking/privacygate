-- 증빙 확장: 신분증·혼인관계·소득·부동산·사진, 자동 검사 결과, 심사 결과(요약·마스킹 사본), 합성 발급대장
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/009-evidence-inspection.sql
BEGIN;
ALTER TABLE evidence_files DROP CONSTRAINT IF EXISTS evidence_files_kind_check;
ALTER TABLE evidence_files ADD CONSTRAINT evidence_files_kind_check
    CHECK (kind IN ('education', 'employment', 'identity', 'marital', 'income', 'property', 'photo'));
CREATE TABLE IF NOT EXISTS evidence_inspections (
    file_id         uuid PRIMARY KEY REFERENCES evidence_files(file_id),
    status          text NOT NULL CHECK (status IN ('done', 'failed')),
    verdict         text NOT NULL CHECK (verdict IN ('verified', 'suspicious', 'unchecked')),  -- 발급대장 대조 결과
    checks          jsonb NOT NULL DEFAULT '{}',     -- 형식·검증숫자·대장 일치·성명/생년월일 일치 (참/거짓만)
    detected        jsonb NOT NULL DEFAULT '{}',     -- 개인정보 종류별 건수 (값 없음)
    proposed        jsonb NOT NULL DEFAULT '{}',     -- 공개 사실 제안 (구간·여부만)
    summary         text CHECK (char_length(summary) <= 300),
    fields_key      text,                            -- 직원 확인용 추출 값 (암호문)
    masked_key      text,                            -- 마스킹 사본 (암호문)
    masked_hash     text,
    masked_type     text CHECK (masked_type IN ('image/png', 'image/jpeg')),
    error           text CHECK (char_length(error) <= 200),
    version         text NOT NULL,
    inspected_at    timestamptz NOT NULL DEFAULT now()
);

-- 심사 통과 후 공개 가능한 결과: 한 줄 요약(구간·여부만)과 마스킹 사본. 원본 삭제 뒤에도 회원 정보 삭제 전까지 유지.
-- 신분증(identity)은 본인 확인용으로만 쓰고 사본을 남기지 않는다 (다른 회원에게 절대 제공하지 않음).
CREATE TABLE IF NOT EXISTS evidence_results (
    file_id         uuid PRIMARY KEY REFERENCES evidence_files(file_id),
    member_id       uuid NOT NULL REFERENCES members(member_id),
    kind            text NOT NULL,
    facts           jsonb NOT NULL DEFAULT '{}',
    summary         text NOT NULL CHECK (char_length(summary) <= 300),
    masked_key      text,
    masked_hash     text,
    masked_type     text CHECK (masked_type IN ('image/png', 'image/jpeg')),
    reviewed_by     uuid NOT NULL REFERENCES users(user_id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (kind <> 'identity' OR masked_key IS NULL)
);
CREATE INDEX IF NOT EXISTS evidence_results_member_idx ON evidence_results (member_id, kind, created_at DESC);

-- 합성 발급대장: 진위 판단 시험용 (실제 기관 연동 아님). 발급번호 = 연도-일련번호-검증숫자(Luhn)
CREATE TABLE IF NOT EXISTS doc_registry (
    issue_no        text PRIMARY KEY CHECK (issue_no ~ '^20[0-9]{2}-[0-9]{6}-[0-9]$'),
    kind            text NOT NULL CHECK (kind IN ('identity', 'marital', 'income', 'property', 'education', 'employment')),
    holder_name     text NOT NULL,
    holder_birth    date,
    revoked         boolean NOT NULL DEFAULT false,
    issued_at       date NOT NULL DEFAULT current_date
);

CREATE OR REPLACE FUNCTION ieum_issue_no(p_year int, p_serial int) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE body text := lpad(p_year::text, 4, '0') || lpad(p_serial::text, 6, '0'); total int := 0; n int; i int;
BEGIN
    FOR i IN 0 .. length(body) - 1 LOOP
        n := substr(body, length(body) - i, 1)::int * CASE WHEN i % 2 = 0 THEN 2 ELSE 1 END;
        total := total + CASE WHEN n > 9 THEN n - 9 ELSE n END;
    END LOOP;
    RETURN lpad(p_year::text, 4, '0') || '-' || lpad(p_serial::text, 6, '0') || '-' || ((10 - total % 10) % 10)::text;
END $$;

-- 회원 코드(A-003)와 문서 종류로 합성 발급번호를 정한다 (doc-inspector 의 시험 문서 생성기와 같은 규칙)
CREATE OR REPLACE FUNCTION register_member_documents(p_member uuid) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO doc_registry (issue_no, kind, holder_name, holder_birth)
    SELECT ieum_issue_no(2026, (ascii(substr(m.pseudo_id, 1, 1)) - 65) * 10000 + substr(m.pseudo_id, 3)::int * 10 + k.idx),
           k.kind, m.name, m.birth_date
      FROM members m,
           (VALUES (1, 'identity'), (2, 'marital'), (3, 'income'), (4, 'property'), (5, 'education'), (6, 'employment')) AS k(idx, kind)
     WHERE m.member_id = p_member
    ON CONFLICT (issue_no) DO NOTHING;
$$;

CREATE OR REPLACE FUNCTION purge_member(p_member uuid, p_notice_days int DEFAULT 30) RETURNS TABLE (storage_key text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid; v_by uuid; v_reason text;
BEGIN
    SELECT m.user_id, m.withdraw_requested_by, m.withdraw_reason INTO v_user, v_by, v_reason
      FROM members m WHERE m.member_id = p_member FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT e.storage_key FROM evidence_files e
                  WHERE (e.member_id = p_member OR e.submitted_by = v_user) AND e.storage_key IS NOT NULL
                 UNION ALL
                 SELECT k FROM evidence_inspections i JOIN evidence_files e ON e.file_id = i.file_id,
                        LATERAL (VALUES (i.fields_key), (i.masked_key)) AS x(k)
                  WHERE (e.member_id = p_member OR e.submitted_by = v_user) AND k IS NOT NULL
                 UNION ALL
                 SELECT r.masked_key FROM evidence_results r WHERE r.member_id = p_member AND r.masked_key IS NOT NULL;
    DELETE FROM evidence_results r WHERE r.member_id = p_member
        OR r.file_id IN (SELECT e.file_id FROM evidence_files e WHERE e.submitted_by = v_user);
    DELETE FROM evidence_inspections i USING evidence_files e
     WHERE i.file_id = e.file_id AND (e.member_id = p_member OR e.submitted_by = v_user);
    DELETE FROM evidence_reviews r USING evidence_files e
     WHERE r.file_id = e.file_id AND (e.member_id = p_member OR e.submitted_by = v_user);
    DELETE FROM evidence_files e WHERE e.member_id = p_member OR e.submitted_by = v_user;
    DELETE FROM intro_files f WHERE f.member_id = p_member
        OR f.consent_id IN (SELECT c.consent_id FROM consents c
                             WHERE c.member_id = p_member OR c.counterpart_member_id = p_member);
    DELETE FROM consents c WHERE c.member_id = p_member OR c.counterpart_member_id = p_member;
    DELETE FROM matches x WHERE x.member_id = p_member OR x.counterpart_member_id = p_member;
    DELETE FROM introductions i WHERE i.member_id = p_member OR i.counterpart_member_id = p_member;
    DELETE FROM assignments a WHERE a.member_id = p_member;
    DELETE FROM members m WHERE m.member_id = p_member;
    IF v_user IS NOT NULL THEN
        DELETE FROM sessions s WHERE s.user_id = v_user;
        DELETE FROM users u WHERE u.user_id = v_user AND u.role = 'member';
        -- 본인이 요청한 탈퇴면 by_staff = false (요청자 기록이 없으면 직원 처리로 본다)
        INSERT INTO withdrawal_notices (user_id, by_staff, reason, account_delete_after)
        VALUES (v_user, v_by IS DISTINCT FROM v_user,
                CASE WHEN v_by IS DISTINCT FROM v_user THEN v_reason END,
                now() + make_interval(days => GREATEST(p_notice_days, 0)))
        ON CONFLICT (user_id) DO UPDATE SET by_staff = EXCLUDED.by_staff, reason = EXCLUDED.reason,
               withdrawn_at = EXCLUDED.withdrawn_at, account_delete_after = EXCLUDED.account_delete_after;
    END IF;
END $$;
REVOKE ALL ON FUNCTION purge_member(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purge_member(uuid, int) TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON evidence_inspections TO app_user;
GRANT SELECT, INSERT ON evidence_results TO app_user;
GRANT SELECT ON doc_registry TO app_user;
CREATE OR REPLACE FUNCTION register_documents_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM register_member_documents(NEW.member_id);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS members_register_documents ON members;
CREATE TRIGGER members_register_documents
    AFTER INSERT ON members
    FOR EACH ROW EXECUTE FUNCTION register_documents_trigger();

DO $$ BEGIN PERFORM register_member_documents(member_id) FROM members; END $$;
COMMIT;
