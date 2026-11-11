-- 회원 담당자 자동 배정: 새 회원이 등록되면 활성 상담 직원 중 한 명을 무작위로 담당자로 지정한다.
-- (시드의 A-001~A-003 → counselor_a 는 시연 시나리오를 위해 03-seed.sql 에서 고정 배정)
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
