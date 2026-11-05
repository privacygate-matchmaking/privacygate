#!/bin/sh
# 앱 전용 계정 pg_app. 테이블 소유자가 아니므로 아래 GRANT 권한만 갖는다.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v app_pw="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE pg_app LOGIN PASSWORD :'app_pw';
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO pg_app;
GRANT SELECT ON users, members, assignments, consents TO pg_app;
GRANT SELECT, INSERT, UPDATE ON evidence_files, evidence_reviews TO pg_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON login_flows, sessions TO pg_app;
-- 감사 기록은 추가만 (수정·삭제 불가)
GRANT INSERT ON audit_log TO pg_app;
GRANT USAGE ON SEQUENCE audit_log_id_seq TO pg_app;
SQL
