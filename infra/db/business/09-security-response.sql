-- 사후 대응: 보안 사건 기록·자동 임시 잠금·계정 정지 (기존 DB 는 upgrade/014-security-response.sql)
-- 앱 계정(app_user)은 사건·잠금 행을 다루고, users.active 변경은 아래 함수로만 한다 (users 테이블 UPDATE 권한 없음).

-- 거부 신호: 같은 계정의 짧은 시간 안 반복 거부를 세기 위한 최소 기록 (감사 로그는 app_user 가 읽을 수 없음)
CREATE TABLE IF NOT EXISTS security_signals (
    id          bigserial PRIMARY KEY,
    user_id     uuid NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('role_denied', 'approval_mismatch')),
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS security_signals_user_idx ON security_signals (user_id, kind, created_at DESC);

-- 자동 임시 잠금: locked_until 이 지나면 저절로 풀린다. 총관리자가 사건 화면에서 먼저 풀 수 있다
CREATE TABLE IF NOT EXISTS account_locks (
    user_id       uuid PRIMARY KEY,
    locked_until  timestamptz NOT NULL,
    reason        text NOT NULL CHECK (char_length(reason) <= 64),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- 보안 사건: 공격 패턴을 탐지하면 internal-api 가 만들고, 중계(transfer-api)가 보낸 사건도 여기에 모은다.
-- 회원 이름·연락처·파일 내용은 넣지 않는다 (계정 id, 직원·회원 코드, 사유 코드만)
CREATE TABLE IF NOT EXISTS security_incidents (
    incident_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind               text NOT NULL CHECK (kind IN ('unauthorized_export', 'approval_mismatch', 'repeated_denials')),
    severity           text NOT NULL CHECK (severity IN ('high', 'medium')),
    subject_user_id    uuid,                                   -- 대상 계정 (Keycloak sub). 탈퇴 후에도 남도록 FK 없음
    subject_code       text CHECK (char_length(subject_code) <= 16),
    subject_role       text CHECK (subject_role IN ('counselor', 'data_admin', 'approver', 'member')),
    source             text NOT NULL CHECK (source IN ('internal-api', 'transfer-api')),
    detail             text CHECK (char_length(detail) <= 200),   -- 사유 코드·경로 템플릿
    trace_id           text CHECK (char_length(trace_id) <= 64),
    blocked            boolean NOT NULL,                       -- 서버가 막았는지 (baseline 에서는 false 로 남는다)
    occurrences        int NOT NULL DEFAULT 1,
    auto_locked_until  timestamptz,
    status             text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'reviewing', 'resolved', 'false_positive')),
    note               text CHECK (char_length(note) <= 500),
    first_seen_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES users(user_id),
    updated_at         timestamptz
);
CREATE INDEX IF NOT EXISTS security_incidents_open_idx ON security_incidents (status, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS security_incidents_subject_idx ON security_incidents (subject_user_id, kind, last_seen_at DESC);

-- 사건별 조치 기록 (화면 표시용. 같은 내용이 감사 로그에도 남는다)
CREATE TABLE IF NOT EXISTS incident_actions (
    action_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_id  uuid NOT NULL REFERENCES security_incidents(incident_id) ON DELETE CASCADE,
    actor_id     uuid NOT NULL REFERENCES users(user_id),
    action       text NOT NULL CHECK (action IN ('status', 'suspend_account', 'restore_account', 'unlock', 'revoke_deliveries')),
    result       text NOT NULL CHECK (char_length(result) <= 64),
    detail       text CHECK (char_length(detail) <= 500),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS incident_actions_incident_idx ON incident_actions (incident_id, created_at);

-- 계정 정지·복구: 활성 총관리자만, 본인·다른 총관리자는 대상이 될 수 없다. 정지하면 그 계정의 직원 세션을 모두 지운다.
-- 반환: 대상 역할 (counselor / approver / member)
DROP FUNCTION IF EXISTS set_account_active(uuid, boolean, uuid);
CREATE FUNCTION set_account_active(p_user uuid, p_active boolean, p_by uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_role text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users u WHERE u.user_id = p_by AND u.role = 'data_admin' AND u.active) THEN
        RAISE EXCEPTION 'actor must be active data_admin';
    END IF;
    IF p_user = p_by THEN
        RAISE EXCEPTION 'cannot change own account';
    END IF;
    SELECT u.role INTO v_role FROM users u WHERE u.user_id = p_user FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'account not found';
    END IF;
    IF v_role = 'data_admin' THEN
        RAISE EXCEPTION 'cannot change data_admin account';
    END IF;
    UPDATE users SET active = p_active WHERE user_id = p_user;
    IF NOT p_active THEN
        DELETE FROM sessions WHERE user_id = p_user;
    ELSE
        DELETE FROM account_locks WHERE user_id = p_user;
    END IF;
    RETURN v_role;
END $$;
REVOKE ALL ON FUNCTION set_account_active(uuid, boolean, uuid) FROM PUBLIC;

GRANT SELECT, INSERT, DELETE ON security_signals TO app_user;
GRANT USAGE ON SEQUENCE security_signals_id_seq TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON account_locks TO app_user;
GRANT SELECT, INSERT, UPDATE ON security_incidents TO app_user;
GRANT SELECT, INSERT ON incident_actions TO app_user;
GRANT EXECUTE ON FUNCTION set_account_active(uuid, boolean, uuid) TO app_user;
