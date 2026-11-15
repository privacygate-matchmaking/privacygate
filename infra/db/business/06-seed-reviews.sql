-- 시드 회원의 "학력·재직 확인됨" 표시에 맞는 심사 기록 채우기.
-- 시드는 확인 표시(education_verified·employment_verified)만 있고 실제 제출·심사 기록이 없어서
-- 회원 화면에는 "미제공"으로, 매칭 반출 검사에서는 "심사 필요"로 나오는 불일치가 있었다.
-- 담당 상담 직원이 서류를 받아 심사를 마쳤고 원본은 보존 기간이 지나 삭제된 상태로 기록한다
-- (원본·마스킹 사본 없음 → 검토 결과 요약만 제공 가능). 이미 같은 종류 증빙이 있으면 건너뛴다.
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
