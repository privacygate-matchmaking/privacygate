-- 탈퇴 요청자·사유 추가 (새 DB 는 01·02 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/006-withdraw-requester.sql
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS withdraw_requested_by uuid REFERENCES users(user_id),
  ADD COLUMN IF NOT EXISTS withdraw_reason text;
GRANT UPDATE (withdraw_requested_by, withdraw_reason) ON members TO app_user;
