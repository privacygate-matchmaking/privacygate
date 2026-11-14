-- matchmaking_business: 업무 DB (service: business-db, internal-api 만 접근)
-- 시간은 모두 UTC(timestamptz) 로 저장하고, 화면에서 한국 시간으로 바꿔 보여 준다.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 사용자: user_id = Keycloak sub. 업무 역할은 토큰이 아니라 여기서 관리한다.
CREATE TABLE users (
    user_id       uuid PRIMARY KEY,
    pseudo_id     text UNIQUE NOT NULL            -- 코드: 직원 A-C01 (앞글자 A~Z + 역할 C/D/P + 2자리), 회원 계정은 회원 코드
                  CHECK (pseudo_id ~ '^[A-Z]-([CDP][0-9]{2}|[0-9]{3})$'),
    display_name  text NOT NULL,
    role          text NOT NULL CHECK (role IN ('counselor', 'data_admin', 'approver', 'member')),
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- 회원 코드: 앞글자 A~Z + 3자리 순번 (A-001 … A-999 다음 B-001). 관리자 화면·감사 로그에서만 쓴다
CREATE SEQUENCE member_code_seq;
CREATE FUNCTION next_member_code() RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint := nextval('member_code_seq');
BEGIN
    IF n > 26 * 999 THEN
        RAISE EXCEPTION 'member code exhausted';
    END IF;
    RETURN chr(65 + ((n - 1) / 999)::int) || '-' || lpad((((n - 1) % 999) + 1)::text, 3, '0');
END $$;

-- 회원 정보 (모두 합성 데이터)
CREATE TABLE members (
    member_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              uuid UNIQUE REFERENCES users(user_id),   -- 외부 로그인 계정이 있는 회원만
    pseudo_id            text UNIQUE NOT NULL DEFAULT next_member_code()   -- 회원 코드 A-001 (관리자 전용)
                         CHECK (pseudo_id ~ '^[A-Z]-[0-9]{3}$'),
    name                 text NOT NULL,                            -- 실명: 직원 화면, 회원에게는 매칭·제공 후에만
    gender               text CHECK (gender IN ('남', '여')),
    birth_date           date,                                     -- 매칭 전에는 만 나이만 공개
    height_cm            smallint CHECK (height_cm BETWEEN 120 AND 230),   -- 본인 신고
    weight_kg            smallint CHECK (weight_kg BETWEEN 30 AND 200),    -- 본인 신고
    education_level      text CHECK (education_level IN ('고졸', '전문대졸', '4년제 대졸', '대학원졸')),  -- 매칭 전 공개
    school               text,                                     -- 학교 (매칭·제공 후, 졸업증명서로 확인)
    major                text,
    job_group            text,                                     -- 직군 (매칭 전 공개)
    company              text,                                     -- 직장 (재직 증빙 통과 시에만 제공)
    introduction         text,
    education_verified   boolean NOT NULL DEFAULT false,           -- 학력 증빙 통과 (매칭 필수 조건)
    employment_verified  boolean NOT NULL DEFAULT false,           -- 재직 증빙 통과 (직장 공개 조건)
    contact_phone        text,
    contact_email        text,
    status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'withdraw_pending')),
    withdraw_requested_at timestamptz,                             -- 탈퇴 요청 시각 (유예 시작)
    withdraw_at          timestamptz,                              -- 이 시각이 지나면 회원 정보를 DB 에서 삭제 (유예 7일)
    withdraw_requested_by uuid REFERENCES users(user_id),          -- 탈퇴를 요청한 직원 (총관리자가 요청한 건은 상담 직원이 철회 불가)
    withdraw_reason      text,                                     -- 탈퇴 사유 (선택)
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- 담당 관계: counselor 가 조회할 수 있는 회원
CREATE TABLE assignments (
    user_id    uuid NOT NULL REFERENCES users(user_id),
    member_id  uuid NOT NULL REFERENCES members(member_id),
    PRIMARY KEY (user_id, member_id)
);

-- 회원 동의: 상대 회원·항목·목적 단위, 만료·철회 가능
CREATE TABLE consents (
    consent_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    consent_no             bigserial UNIQUE,                   -- 화면 표시용 번호 (C-1, C-2 …)
    member_id              uuid NOT NULL REFERENCES members(member_id),
    counterpart_member_id  uuid NOT NULL REFERENCES members(member_id),
    item                   text NOT NULL CHECK (item IN ('profile', 'photo', 'contact')),
    purpose                text NOT NULL,
    granted_at             timestamptz NOT NULL DEFAULT now(),
    expires_at             timestamptz NOT NULL,
    revoked_at             timestamptz
);

-- 증빙: 원본은 evidence-storage 에 AES-GCM 암호문으로만 저장
CREATE TABLE evidence_files (
    file_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id         uuid NOT NULL REFERENCES members(member_id),
    submitted_by      uuid NOT NULL REFERENCES users(user_id),
    kind              text NOT NULL DEFAULT 'education' CHECK (kind IN ('education', 'employment')),  -- 학력 / 재직
    reviewer_user_id  uuid REFERENCES users(user_id),       -- 배정된 data_admin
    storage_key       text,                                  -- 삭제 후 NULL
    key_id            text NOT NULL,
    file_hash         text NOT NULL,                         -- sha256 hex
    status            text NOT NULL CHECK (status IN ('submitted', 'in_review', 'reviewed', 'deleted')),
    delete_after      timestamptz NOT NULL,
    legal_hold        boolean NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE evidence_reviews (
    file_id           uuid PRIMARY KEY REFERENCES evidence_files(file_id),
    result            text NOT NULL CHECK (result IN ('passed', 'rejected')),
    reviewer_user_id  uuid NOT NULL REFERENCES users(user_id),
    criteria_date     date NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- 소개 관계: 서로 소개된 회원 쌍. 회원은 소개된 상대에게만 동의를 등록할 수 있다 (외부 화면의 counterparts)
CREATE TABLE introductions (
    member_id              uuid NOT NULL REFERENCES members(member_id),
    counterpart_member_id  uuid NOT NULL REFERENCES members(member_id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (member_id, counterpart_member_id),
    CHECK (member_id <> counterpart_member_id)
);

-- 매칭: 회원이 소개된 상대에게 '매칭'을 누른 기록. 서로 누르면 양쪽 소개 자료 제공 동의가 만들어진다
CREATE TABLE matches (
    member_id              uuid NOT NULL REFERENCES members(member_id),
    counterpart_member_id  uuid NOT NULL REFERENCES members(member_id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    cancelled_at           timestamptz,
    PRIMARY KEY (member_id, counterpart_member_id),
    CHECK (member_id <> counterpart_member_id)
);

-- 소개 자료 발송: 중계의 file_id·request_id·approval_id(UUID)를 화면용 이름(A-001_file1)과 잇는다
CREATE TABLE intro_files (
    label        text PRIMARY KEY,                             -- <회원 가명 ID>_file<순번>
    member_id    uuid NOT NULL REFERENCES members(member_id),
    seq          int  NOT NULL,
    consent_id   uuid NOT NULL REFERENCES consents(consent_id),
    file_id      uuid UNIQUE NOT NULL,                         -- 중계 transfer_files.file_id
    request_id   uuid UNIQUE NOT NULL,                         -- 중계 export_requests.request_id
    approval_id  uuid UNIQUE,                                  -- 승인 후 중계가 준 approval_id
    created_by   uuid NOT NULL REFERENCES users(user_id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (member_id, seq)
);

-- 관리자 전체 회원 내보내기 결과: 파일은 evidence-storage/exports/ 에 암호문으로만 두고 브라우저로 내보내지 않는다
CREATE TABLE member_exports (
    export_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_by        uuid NOT NULL REFERENCES users(user_id),
    row_count         int  NOT NULL,
    storage_key       text NOT NULL,
    file_hash         text NOT NULL,                    -- sha256 hex
    transfer_file_id  uuid,                             -- 중계 등록 시 받은 file_id
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- 직원 알림 (화면 오른쪽 위 종 아이콘). 본인 알림만 읽기·읽음 처리·삭제
CREATE TABLE notifications (
    notification_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    kind             text NOT NULL,                  -- evidence_submitted, match_made, intro_requested … (화면 아이콘·분류용)
    title            text NOT NULL,
    body             text,
    link_view        text,                           -- 누르면 이동할 화면 (members / manage / evidence / approvals)
    created_at       timestamptz NOT NULL DEFAULT now(),
    read_at          timestamptz
);
CREATE INDEX notifications_user_idx ON notifications (user_id, created_at DESC);

-- OIDC 로그인 진행 중 임시값 (한 번 쓰면 삭제)
CREATE TABLE login_flows (
    state_hash     bytea PRIMARY KEY,
    binding_hash   bytea NOT NULL,
    nonce          text NOT NULL,
    code_verifier  text NOT NULL,
    expires_at     timestamptz NOT NULL
);

-- 서버 세션: 세션 ID 는 해시로만 저장
CREATE TABLE sessions (
    session_hash         bytea PRIMARY KEY,
    user_id              uuid NOT NULL REFERENCES users(user_id),
    csrf_token           text NOT NULL,
    id_token             text NOT NULL,          -- 로그아웃 시 Keycloak 에 전달
    access_token         text NOT NULL,          -- transfer-api 호출용 (브라우저에 주지 않음)
    refresh_token        text,
    created_at           timestamptz NOT NULL,
    last_seen_at         timestamptz NOT NULL,
    absolute_expires_at  timestamptz NOT NULL
);
CREATE INDEX sessions_user_idx ON sessions (user_id);

-- 감사 기록: 앱 계정은 INSERT 만 가능 (02 스크립트)
CREATE TABLE audit_log (
    id           bigserial PRIMARY KEY,
    ts           timestamptz NOT NULL,
    trace_id     text NOT NULL,
    actor        text,
    role         text,
    action       text NOT NULL,
    target_type  text,
    target_id    text,
    result       text NOT NULL CHECK (result IN ('allow', 'deny', 'error')),
    reason       text
);

-- 탈퇴 안내: 회원 행이 지워진 뒤에도 로그인한 본인에게 "탈퇴된 계정"과 (직원 처리 시) 사유를 보여 주기 위한 최소 기록.
-- user_id 는 Keycloak 계정 id (users 행은 이미 삭제되므로 FK 없음). 이름·회원 코드는 남기지 않는다.
-- account_delete_after 가 지나면 internal-api 주기 작업이 Keycloak 계정을 지우고 이 행도 지운다.
CREATE TABLE withdrawal_notices (
    user_id               uuid PRIMARY KEY,
    by_staff              boolean NOT NULL,
    reason                text CHECK (char_length(reason) <= 200),
    withdrawn_at          timestamptz NOT NULL DEFAULT now(),
    account_delete_after  timestamptz NOT NULL
);

-- 회원 삭제(탈퇴 확정): 회원과 관련 행(동의·매칭·소개 관계·담당·증빙·소개 자료 기록·회원 로그인 계정 행)을 모두 지운다.
-- 앱 계정(app_user)에는 각 테이블 DELETE 권한을 주지 않고 이 함수 실행 권한만 준다 (삭제 범위를 함수로 고정).
-- 반환: 지워야 할 증빙 암호문 파일의 storage_key 목록 (파일 삭제는 internal-api 가 한다). 감사 로그는 남긴다.
-- 회원 로그인 계정이 있으면 탈퇴 안내 기록(withdrawal_notices)을 p_notice_days 일 동안 남긴다.
CREATE FUNCTION purge_member(p_member uuid, p_notice_days int DEFAULT 30) RETURNS TABLE (storage_key text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid; v_by uuid; v_reason text;
BEGIN
    SELECT m.user_id, m.withdraw_requested_by, m.withdraw_reason INTO v_user, v_by, v_reason
      FROM members m WHERE m.member_id = p_member FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT e.storage_key FROM evidence_files e
                  WHERE (e.member_id = p_member OR e.submitted_by = v_user) AND e.storage_key IS NOT NULL;
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
