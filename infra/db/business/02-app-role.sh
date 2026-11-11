#!/bin/sh
# 앱 전용 계정 app_user. 테이블 소유자가 아니므로 아래 GRANT 권한만 갖는다.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v app_pw="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE app_user LOGIN PASSWORD :'app_pw';
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT ON users, members, assignments, introductions TO app_user;
-- 회원 관리: 허용 항목 수정과 탈퇴(이름·연락처 삭제)만. 회원 행 삭제는 불가
GRANT UPDATE (birth_date, height_cm, weight_kg, education_level, school, major, job_group, company, introduction,
              education_verified, employment_verified, name, contact_phone, contact_email, status, withdrawn_at) ON members TO app_user;
GRANT SELECT, INSERT, UPDATE ON matches TO app_user;
GRANT SELECT, INSERT, UPDATE ON member_exports TO app_user;
-- 동의: 회원이 등록·철회 (삭제는 불가, 철회는 revoked_at 기록)
GRANT SELECT, INSERT, UPDATE ON consents TO app_user;
GRANT USAGE ON SEQUENCE consents_consent_no_seq TO app_user;
GRANT SELECT, INSERT, UPDATE ON intro_files TO app_user;
GRANT SELECT, INSERT, UPDATE ON evidence_files, evidence_reviews TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON login_flows, sessions TO app_user;
-- 감사 기록은 추가만 (수정·삭제 불가)
GRANT INSERT ON audit_log TO app_user;
GRANT USAGE ON SEQUENCE audit_log_id_seq TO app_user;
SQL
