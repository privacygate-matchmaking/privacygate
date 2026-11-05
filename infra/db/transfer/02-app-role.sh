#!/bin/sh
# 앱 전용 계정 app_user. 감사 기록은 추가만 가능.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v app_pw="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE app_user LOGIN PASSWORD :'app_pw';
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE ON transfer_files, export_requests, approvals, deliveries TO app_user;
GRANT INSERT ON audit_log TO app_user;
GRANT USAGE ON SEQUENCE audit_log_id_seq TO app_user;
SQL
