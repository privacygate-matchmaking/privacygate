-- matchmaking_transfer: 중계 DB (service: transfer-db, transfer-api 만 접근)
-- 사용자 ID(requester_id, approver_id, recipient_id)는 Keycloak sub. 시간은 UTC.

-- 반출 파일: 검사 결과와 고정된 버전·해시
CREATE TABLE transfer_files (
    file_id       uuid PRIMARY KEY,
    file_version  int  NOT NULL DEFAULT 1,
    file_hash     text NOT NULL,                     -- sha256 hex
    uploaded_by   uuid NOT NULL,
    staging_key   text,                              -- transfer-staging 경로 (검사 후 NULL)
    verified_key  text,                              -- transfer-verified 경로 (passed 일 때만)
    scan_status   text NOT NULL DEFAULT 'pending'
                  CHECK (scan_status IN ('pending', 'passed', 'blocked', 'error')),
    scan_reason   text,
    export_banned boolean NOT NULL DEFAULT false,    -- 반출 금지 자료는 승인으로도 허용 안 함
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (file_id, file_version)
);

-- 반출 신청
CREATE TABLE export_requests (
    request_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id    uuid NOT NULL,
    file_id         uuid NOT NULL,
    file_version    int  NOT NULL,
    file_hash       text NOT NULL,
    recipient_id    uuid NOT NULL,                   -- 받을 회원의 user_id
    member_id       uuid NOT NULL,                   -- 자료 대상 회원 (동의 확인용)
    consent_id      uuid,
    purpose         text NOT NULL,
    request_status  text NOT NULL DEFAULT 'pending'
                    CHECK (request_status IN ('pending', 'approved', 'rejected', 'revoked', 'expired')),
    expires_at      timestamptz NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (file_id, file_version) REFERENCES transfer_files (file_id, file_version)
);

-- 승인: 신청자와 승인자는 달라야 한다 (DB 에서도 한 번 더 막음)
CREATE TABLE approvals (
    approval_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id      uuid UNIQUE NOT NULL REFERENCES export_requests(request_id),
    requester_id    uuid NOT NULL,
    approver_id     uuid NOT NULL,
    approved_file_id       uuid NOT NULL,
    approved_file_version  int  NOT NULL,
    approved_file_hash     text NOT NULL,
    expires_at      timestamptz NOT NULL,
    revoked_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (approver_id <> requester_id)
);

-- 전달: 회원은 delivery_id 로만 요청, 서버가 approval 의 파일을 고른다
CREATE TABLE deliveries (
    delivery_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    approval_id   uuid NOT NULL REFERENCES approvals(approval_id),
    recipient_id  uuid NOT NULL,
    downloaded_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX deliveries_recipient_idx ON deliveries (recipient_id);

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
