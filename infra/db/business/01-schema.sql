-- matchmaking_business: 업무 DB (service: business-db, internal-api 만 접근)
-- 시간은 모두 UTC(timestamptz) 로 저장하고, 화면에서 한국 시간으로 바꿔 보여 준다.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 사용자: user_id = Keycloak sub. 업무 역할은 토큰이 아니라 여기서 관리한다.
CREATE TABLE users (
    user_id       uuid PRIMARY KEY,
    pseudo_id     text UNIQUE NOT NULL,           -- 로그·화면용 가명 ID
    display_name  text NOT NULL,
    role          text NOT NULL CHECK (role IN ('counselor', 'data_admin', 'approver', 'member')),
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- 회원 정보 (모두 합성 데이터)
CREATE TABLE members (
    member_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid UNIQUE REFERENCES users(user_id),   -- 외부 로그인 계정이 있는 회원만
    pseudo_id      text UNIQUE NOT NULL,
    name           text NOT NULL,
    birth_year     int,
    job            text,
    contact_phone  text,
    contact_email  text,
    status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'withdrawn')),
    withdrawn_at   timestamptz,                             -- 탈퇴 시 이름·연락처는 지우고 기록용 행만 남긴다
    created_at     timestamptz NOT NULL DEFAULT now()
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
