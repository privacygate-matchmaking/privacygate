-- 이미 만든 DB 에 회원 상태(탈퇴)·매칭·총관리자 계정을 추가한다 (새 DB 는 01~03 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/003-matching-member-admin.sql
ALTER TABLE members ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'withdrawn'));
ALTER TABLE members ADD COLUMN IF NOT EXISTS withdrawn_at timestamptz;

CREATE TABLE IF NOT EXISTS matches (
    member_id              uuid NOT NULL REFERENCES members(member_id),
    counterpart_member_id  uuid NOT NULL REFERENCES members(member_id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    cancelled_at           timestamptz,
    PRIMARY KEY (member_id, counterpart_member_id),
    CHECK (member_id <> counterpart_member_id)
);

GRANT UPDATE (job, birth_year, name, contact_phone, contact_email, status, withdrawn_at) ON members TO app_user;
GRANT SELECT, INSERT, UPDATE ON matches TO app_user;

INSERT INTO users (user_id, pseudo_id, display_name, role) VALUES
  ('11111111-1111-4111-8111-111111111105', 'S-A01', 'super_admin', 'data_admin') ON CONFLICT DO NOTHING;

-- 미리 넣어 둔 동의(회원 1 → member_b)를 지우고, 회원 1 의 매칭 기록으로 바꾼다
DELETE FROM consents
 WHERE member_id = 'bbbbbbbb-0000-4000-8000-000000000001'
   AND counterpart_member_id = 'bbbbbbbb-0000-4000-8000-000000000003'
   AND purpose = 'introduction';
INSERT INTO matches (member_id, counterpart_member_id) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003') ON CONFLICT DO NOTHING;
