#!/bin/sh
# 앱 전용 계정 pg_app. 감사 기록은 추가만 가능.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v app_pw="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE pg_app LOGIN PASSWORD :'app_pw';
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO pg_app;
GRANT SELECT, INSERT, UPDATE ON transfer_files, export_requests, approvals, deliveries TO pg_app;
GRANT INSERT ON audit_log TO pg_app;
GRANT USAGE ON SEQUENCE audit_log_id_seq TO pg_app;
SQL
