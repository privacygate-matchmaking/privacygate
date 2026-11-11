-- 이미 만든 matchmaking_business DB 에 introductions·member_exports 를 추가한다 (새로 만드는 DB 는 01~03 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/001-introductions-exports.sql
CREATE TABLE IF NOT EXISTS introductions (
    member_id              uuid NOT NULL REFERENCES members(member_id),
    counterpart_member_id  uuid NOT NULL REFERENCES members(member_id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (member_id, counterpart_member_id),
    CHECK (member_id <> counterpart_member_id)
);
CREATE TABLE IF NOT EXISTS member_exports (
    export_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_by        uuid NOT NULL REFERENCES users(user_id),
    row_count         int  NOT NULL,
    storage_key       text NOT NULL,
    file_hash         text NOT NULL,
    transfer_file_id  uuid,
    created_at        timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON introductions TO app_user;
GRANT SELECT, INSERT, UPDATE ON member_exports TO app_user;
GRANT INSERT, UPDATE ON consents TO app_user;
INSERT INTO introductions (member_id, counterpart_member_id) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003'),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000001'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000003'),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000002')
ON CONFLICT DO NOTHING;
