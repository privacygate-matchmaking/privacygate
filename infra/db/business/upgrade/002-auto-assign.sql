-- 이미 만든 DB 에 counselor_b 직원과 담당자 무작위 자동 배정을 추가한다 (새 DB 는 03·04 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/002-auto-assign.sql
INSERT INTO users (user_id, pseudo_id, display_name, role) VALUES
  ('11111111-1111-4111-8111-111111111104', 'S-C02', 'counselor_b', 'counselor') ON CONFLICT DO NOTHING;
-- 기존 시드의 M-004~M-008 은 counselor_a 에 묶인 적이 없으므로 아래에서 무작위 배정된다
CREATE OR REPLACE FUNCTION assign_random_counselor() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO assignments (user_id, member_id)
    SELECT u.user_id, NEW.member_id
      FROM users u
     WHERE u.role = 'counselor' AND u.active
     ORDER BY random()
     LIMIT 1
    ON CONFLICT DO NOTHING;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS members_assign_counselor ON members;
CREATE TRIGGER members_assign_counselor
    AFTER INSERT ON members
    FOR EACH ROW EXECUTE FUNCTION assign_random_counselor();

-- 담당자가 없는 기존 회원도 무작위 배정
INSERT INTO assignments (user_id, member_id)
SELECT (SELECT u.user_id FROM users u
         WHERE u.role = 'counselor' AND u.active AND m.member_id IS NOT NULL  -- m 참조: 회원마다 다시 뽑게 함
         ORDER BY random() LIMIT 1), m.member_id
  FROM members m
 WHERE NOT EXISTS (SELECT 1 FROM assignments a WHERE a.member_id = m.member_id);
