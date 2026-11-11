-- 직원 알림 (새 DB 는 01·02·04 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/007-notifications.sql
CREATE TABLE IF NOT EXISTS notifications (
    notification_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    kind             text NOT NULL,
    title            text NOT NULL,
    body             text,
    link_view        text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    read_at          timestamptz
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON notifications (user_id, created_at DESC);
GRANT SELECT, INSERT, UPDATE, DELETE ON notifications TO app_user;
CREATE OR REPLACE FUNCTION assign_random_counselor() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    WITH picked AS (
        INSERT INTO assignments (user_id, member_id)
        SELECT u.user_id, NEW.member_id
          FROM users u
         WHERE u.role = 'counselor' AND u.active
         ORDER BY random()
         LIMIT 1
        ON CONFLICT DO NOTHING
        RETURNING user_id
    )
    -- 배정된 상담 직원에게 알림
    INSERT INTO notifications (user_id, kind, title, body, link_view)
    SELECT user_id, 'member_assigned', '새 담당 회원 배정', NEW.pseudo_id || ' ' || NEW.name || ' 회원이 배정되었습니다.', 'members'
      FROM picked;
    RETURN NEW;
END $$;
