-- 시드 회원 확인 표시와 심사 기록 맞추기 (새 DB 는 06-seed-reviews.sql 에 포함)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/011-seed-reviews.sql
BEGIN;
WITH targets AS (
    SELECT m.member_id, m.pseudo_id, coalesce(m.name, '회원') AS name, k.kind, a.user_id AS staff
      FROM members m
      JOIN LATERAL (SELECT user_id FROM assignments a WHERE a.member_id = m.member_id ORDER BY user_id LIMIT 1) a ON true
      CROSS JOIN LATERAL (VALUES ('education', m.education_verified), ('employment', m.employment_verified)) AS k(kind, verified)
     WHERE k.verified
       AND NOT EXISTS (SELECT 1 FROM evidence_files e WHERE e.member_id = m.member_id AND e.kind = k.kind)
), files AS (
    INSERT INTO evidence_files (member_id, submitted_by, kind, reviewer_user_id, storage_key, key_id, file_hash,
                                status, delete_after, file_name)
    SELECT member_id, staff, kind, staff, NULL, 'seed', 'seed-record', 'deleted', now(),
           pseudo_id || '(' || name || ')_' || kind || '.pdf'
      FROM targets
    RETURNING file_id, member_id, kind, reviewer_user_id
), reviews AS (
    INSERT INTO evidence_reviews (file_id, result, reviewer_user_id, criteria_date)
    SELECT file_id, 'passed', reviewer_user_id, current_date FROM files
    RETURNING file_id
)
INSERT INTO evidence_results (file_id, member_id, kind, facts, summary, reviewed_by)
SELECT f.file_id, f.member_id, f.kind, '{}',
       CASE f.kind WHEN 'education' THEN '학력 증빙 검토 완료' ELSE '재직 증빙 검토 완료' END, f.reviewer_user_id
  FROM files f JOIN reviews r ON r.file_id = f.file_id;
COMMIT;
