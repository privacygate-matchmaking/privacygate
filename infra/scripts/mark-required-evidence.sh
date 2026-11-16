#!/bin/sh
# [시험 전용] 회원의 매칭 필수 증빙(신분증·학력·프로필 사진·혼인관계증명서 '미혼')을 "담당 직원이 받아 심사 통과, 원본은 보존 기간 지나 삭제" 상태로 기록한다.
# 실제 서류 제출·자동 검사·직원 심사를 건너뛰므로 시연 준비용으로만 쓴다 (db_owner 권한, 앱 경로 아님).
# 이미 같은 종류 증빙이 통과돼 있으면 건너뛴다. 원본·마스킹 사본이 없으므로 문서 사본·프로필 사진은 상대에게 제공되지 않는다
# (사진 공개까지 시연할 회원은 실제로 사진을 올려 심사받는다). reset-test-data.sh 는 이 기록(key_id='test')을 지우지 않는다.
# 사용 (privacygate 폴더, 내부 스택 실행 중): ./infra/scripts/mark-required-evidence.sh A-003 A-001
set -eu
cd "$(dirname "$0")/../.."
[ "$#" -ge 1 ] || { echo "회원 코드를 하나 이상 입력하세요 (예: A-003 A-001)" >&2; exit 1; }
list=""
for code in "$@"; do
  echo "$code" | grep -Eq '^[A-Z]-[0-9]{3}$' || { echo "회원 코드 형식이 아닙니다: $code" >&2; exit 1; }
  list="$list${list:+,}'$code'"
done
docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 <<SQL
BEGIN;
WITH targets AS (
    SELECT m.member_id, m.pseudo_id, coalesce(m.name, '회원') AS name, k.kind, a.user_id AS staff
      FROM members m
      JOIN LATERAL (SELECT user_id FROM assignments a WHERE a.member_id = m.member_id ORDER BY user_id LIMIT 1) a ON true
      CROSS JOIN (VALUES ('identity'), ('education'), ('photo'), ('marital')) AS k(kind)
     WHERE m.pseudo_id IN ($list) AND m.status = 'active'
       AND NOT EXISTS (SELECT 1 FROM evidence_files e JOIN evidence_reviews r ON r.file_id = e.file_id
                        WHERE e.member_id = m.member_id AND e.kind = k.kind AND r.result = 'passed')
), files AS (
    INSERT INTO evidence_files (member_id, submitted_by, kind, reviewer_user_id, storage_key, key_id, file_hash,
                                status, delete_after, file_name)
    SELECT member_id, staff, kind, staff, NULL, 'test', 'test-record', 'deleted', now(),
           pseudo_id || '(' || name || ')_' || kind || CASE kind WHEN 'photo' THEN '.jpg' ELSE '.pdf' END
      FROM targets
    RETURNING file_id, member_id, kind, reviewer_user_id
), reviews AS (
    INSERT INTO evidence_reviews (file_id, result, reviewer_user_id, criteria_date)
    SELECT file_id, 'passed', reviewer_user_id, current_date FROM files
    RETURNING file_id
)
INSERT INTO evidence_results (file_id, member_id, kind, facts, summary, reviewed_by)
SELECT f.file_id, f.member_id, f.kind, CASE f.kind WHEN 'marital' THEN '{"status": "미혼"}' ELSE '{}' END::jsonb,
       CASE f.kind WHEN 'identity' THEN '본인 확인 완료' WHEN 'photo' THEN '프로필 사진 검토 완료 (위치 등 메타데이터 제거)'
                   WHEN 'marital' THEN '혼인관계 확인: 미혼'
                   ELSE '학력 증빙 검토 완료' END, f.reviewer_user_id
  FROM files f JOIN reviews r ON r.file_id = f.file_id;
UPDATE members SET education_verified = true WHERE pseudo_id IN ($list);
SELECT m.pseudo_id, m.name, e.kind, r.result
  FROM members m JOIN evidence_files e ON e.member_id = m.member_id JOIN evidence_reviews r ON r.file_id = e.file_id
 WHERE m.pseudo_id IN ($list) AND e.kind IN ('identity', 'education', 'photo', 'marital') ORDER BY 1, 3;
COMMIT;
SQL
