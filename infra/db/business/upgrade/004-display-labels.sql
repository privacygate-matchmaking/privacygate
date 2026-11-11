-- 화면용 짧은 이름: 동의 번호(C-n), 소개 자료 이름(M-001_file1) (새 DB 는 01·02 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/004-display-labels.sql
ALTER TABLE consents ADD COLUMN IF NOT EXISTS consent_no bigserial UNIQUE;
CREATE TABLE IF NOT EXISTS intro_files (
    label        text PRIMARY KEY,
    member_id    uuid NOT NULL REFERENCES members(member_id),
    seq          int  NOT NULL,
    consent_id   uuid NOT NULL REFERENCES consents(consent_id),
    file_id      uuid UNIQUE NOT NULL,
    request_id   uuid UNIQUE NOT NULL,
    approval_id  uuid UNIQUE,
    created_by   uuid NOT NULL REFERENCES users(user_id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (member_id, seq)
);
GRANT USAGE ON SEQUENCE consents_consent_no_seq TO app_user;
GRANT SELECT, INSERT, UPDATE ON intro_files TO app_user;
