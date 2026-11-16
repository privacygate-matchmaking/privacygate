#!/bin/bash
# 시험하면서 생긴 더미 데이터 정리 (시드 데이터·계정은 유지). privacygate 폴더에서 실행
#
#   ./infra/scripts/reset-test-data.sh check    지울 대상 개수만 보기 (아무것도 바꾸지 않음)
#   ./infra/scripts/reset-test-data.sh apply    실제로 지우기 (되돌릴 수 없음, 먼저 check)
#
# 지우는 것
#   업무 DB  : 가입 폼으로 만든 회원(계정·증빙·동의 포함), 시험 중 시드 회원에 올린 증빙, 직원 가입 신청·승인 직원,
#              알림, 탈퇴 안내 기록, 소개 자료 기록(intro_files), 동의, 시드 외 매칭 기록, 관리자 내보내기 기록
#   중계 DB  : 유료 매칭(주문·이용권·신청·공개 동의·만남 일정), 반출 신청·승인·전달·중계 파일
#   파일     : 위 기록에 딸린 증빙 저장소 암호문·중계 대기/검사 파일
#   Keycloak : 가입 폼 회원 계정, 직원 가입 신청(승인 포함) 계정
# 유지하는 것
#   mark-required-evidence.sh 로 넣은 필수 증빙 기록(key_id='test'), 시드 회원 20명·시드 직원 4명·member_b·member_001~020 계정, 시드 심사 기록, 소개 관계, 발급대장, 감사 로그(audit_log)
#   시드 회원의 시험 중 바뀐 프로필 값(키·연락처 등)은 되돌리지 않는다. 학력·재직 확인 표시는 남은 심사 결과로 다시 맞춘다
set -euo pipefail
source "$(dirname "$0")/compare/_compose.sh"
MODE="${1:-check}"
SEED_STAFF="'A-C01','A-C02','A-D01','A-P01'"

bdb() { pg_compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 -At "$@"; }
tdb() { pg_compose exec -T transfer-db psql -U db_owner -d matchmaking_transfer -v ON_ERROR_STOP=1 -At "$@"; }

check() {
  echo "== 업무 DB"
  bdb <<SQL
SELECT '가입 폼 회원       ' || count(*) FROM members WHERE privacy_consent_version IS NOT NULL;
SELECT '시험 증빙(시드 외) ' || count(*) FROM evidence_files WHERE key_id NOT IN ('seed', 'test');
SELECT '시험 직원          ' || count(*) FROM users WHERE role <> 'member' AND pseudo_id NOT IN ($SEED_STAFF);
SELECT '직원 가입 신청     ' || count(*) FROM staff_signups;
SELECT '알림               ' || count(*) FROM notifications;
SELECT '동의               ' || count(*) FROM consents;
SELECT '소개 자료 기록     ' || count(*) FROM intro_files;
SELECT '관리자 내보내기    ' || count(*) FROM member_exports;
SELECT '탈퇴 대기 시드 회원 ' || count(*) FROM members WHERE status <> 'active' AND privacy_consent_version IS NULL;
SELECT '탈퇴 안내 기록     ' || count(*) FROM withdrawal_notices;
SQL
  echo "== 중계 DB"
  tdb <<'SQL'
SELECT '매칭 신청          ' || count(*) FROM matching_requests;
SELECT '이용권 주문        ' || count(*) FROM matching_orders;
SELECT '만남 일정 제안     ' || count(*) FROM matching_meeting_proposals;
SELECT '공개 동의(매칭)    ' || count(*) FROM matching_grants;
SELECT '반출 신청          ' || count(*) FROM export_requests;
SELECT '반출 승인          ' || count(*) FROM approvals;
SELECT '중계 파일          ' || count(*) FROM transfer_files;
SQL
}

# 업무 DB 정리 SQL. 결과 줄: K|<저장소 키>  /  U|<Keycloak 사용자 id>
# (macOS 기본 bash 3.2 는 $( ) 안의 heredoc 에 괄호가 있으면 해석하지 못해 함수로 분리)
business_cleanup() {
  bdb <<SQL
BEGIN;
CREATE TEMP TABLE k (key text) ON COMMIT DROP;
CREATE TEMP TABLE kc (user_id uuid) ON COMMIT DROP;
-- 1) 가입 폼 회원: purge_member 로 회원·증빙·동의·매칭·배정·계정 행까지 삭제
INSERT INTO kc SELECT user_id FROM members WHERE privacy_consent_version IS NOT NULL AND user_id IS NOT NULL;
INSERT INTO k SELECT p.storage_key FROM members m, LATERAL purge_member(m.member_id, 0) p
 WHERE m.privacy_consent_version IS NOT NULL;
DELETE FROM withdrawal_notices;
-- 2) 시험 중 시드 회원에 올린 증빙 (시드 심사 기록 key_id='seed', 시연 준비 기록 key_id='test' 는 유지)
CREATE TEMP TABLE tf ON COMMIT DROP AS SELECT file_id, storage_key FROM evidence_files WHERE key_id NOT IN ('seed', 'test');
INSERT INTO k SELECT storage_key FROM tf WHERE storage_key IS NOT NULL;
INSERT INTO k SELECT x FROM evidence_inspections i JOIN tf USING (file_id),
              LATERAL (VALUES (i.fields_key), (i.masked_key)) v(x) WHERE x IS NOT NULL;
INSERT INTO k SELECT masked_key FROM evidence_results r JOIN tf USING (file_id) WHERE masked_key IS NOT NULL;
DELETE FROM evidence_results r USING tf WHERE r.file_id = tf.file_id;
DELETE FROM evidence_inspections i USING tf WHERE i.file_id = tf.file_id;
DELETE FROM evidence_reviews r USING tf WHERE r.file_id = tf.file_id;
DELETE FROM evidence_files e USING tf WHERE e.file_id = tf.file_id;
UPDATE members m SET
  education_verified  = EXISTS (SELECT 1 FROM evidence_results r WHERE r.member_id = m.member_id AND r.kind = 'education'),
  employment_verified = EXISTS (SELECT 1 FROM evidence_results r WHERE r.member_id = m.member_id AND r.kind = 'employment');
-- 3) 소개 자료·동의·시드 외 매칭·관리자 내보내기
DELETE FROM intro_files;
DELETE FROM consents;
DELETE FROM matches WHERE NOT (member_id = 'bbbbbbbb-0000-4000-8000-000000000001'
                           AND counterpart_member_id = 'bbbbbbbb-0000-4000-8000-000000000003');
INSERT INTO k SELECT storage_key FROM member_exports;
DELETE FROM member_exports;
-- 4) 시험 중 탈퇴 요청된 시드 회원은 활동 상태로
UPDATE members SET status = 'active', withdraw_requested_at = NULL, withdraw_at = NULL,
                   withdraw_requested_by = NULL, withdraw_reason = NULL WHERE status <> 'active';
-- 5) 직원 가입 신청·승인 직원: 담당 회원은 시드 상담 직원 중 담당이 적은 쪽으로 넘기고 삭제
INSERT INTO kc SELECT user_id FROM staff_signups;
DELETE FROM staff_signups;
CREATE TEMP TABLE ts ON COMMIT DROP AS
  SELECT user_id FROM users WHERE role <> 'member' AND pseudo_id NOT IN ($SEED_STAFF);
INSERT INTO kc SELECT user_id FROM ts;
INSERT INTO assignments (user_id, member_id)
SELECT (SELECT u.user_id FROM users u WHERE u.pseudo_id IN ('A-C01','A-C02')
         ORDER BY (SELECT count(*) FROM assignments b WHERE b.user_id = u.user_id), u.pseudo_id LIMIT 1), a.member_id
  FROM assignments a JOIN ts USING (user_id)
 WHERE NOT EXISTS (SELECT 1 FROM assignments x WHERE x.member_id = a.member_id AND x.user_id NOT IN (SELECT user_id FROM ts))
ON CONFLICT DO NOTHING;
DELETE FROM assignments a USING ts WHERE a.user_id = ts.user_id;
UPDATE evidence_files e SET reviewer_user_id = NULL FROM ts WHERE e.reviewer_user_id = ts.user_id;
DELETE FROM sessions s USING ts WHERE s.user_id = ts.user_id;
DELETE FROM users u USING ts WHERE u.user_id = ts.user_id;
-- 6) 알림 (모두 시험 중 생긴 것)
DELETE FROM notifications;
SELECT 'K|' || key FROM k WHERE key IS NOT NULL AND key <> '';
SELECT 'U|' || user_id FROM kc;
COMMIT;
SQL
}

apply() {
  local keys users out
  echo "== 업무 DB 정리"
  out=$(business_cleanup)
  keys=$(printf '%s\n' "$out" | sed -n 's/^K|//p' | sort -u)
  users=$(printf '%s\n' "$out" | sed -n 's/^U|//p' | sort -u)
  echo "  증빙 저장소 파일 $(printf '%s' "$keys" | grep -c . || true)개, Keycloak 계정 $(printf '%s' "$users" | grep -c . || true)개 정리 대상"

  echo "== 중계 DB 정리"
  tdb <<'SQL'
BEGIN;
DELETE FROM matching_meeting_replies;
DELETE FROM matching_meeting_proposals;
DELETE FROM matching_grants;
DELETE FROM matching_credit_events;
DELETE FROM matching_requests;
DELETE FROM matching_memberships;
DELETE FROM matching_orders;
DELETE FROM matching_profiles;
DELETE FROM deliveries;
DELETE FROM approvals;
DELETE FROM export_requests;
DELETE FROM transfer_files;
COMMIT;
SQL

  echo "== 파일 정리"
  if [ -n "$keys" ]; then
    printf '%s\n' "$keys" | pg_compose exec -T internal-api python -c '
import sys
from app import storage
n = 0
for line in sys.stdin:
    key = line.strip()
    if key and key != "seed":
        try:
            storage.delete(key); n += 1
        except Exception as exc:
            print("  건너뜀:", type(exc).__name__)
print(f"  증빙 저장소 파일 {n}개 삭제")'
  fi
  pg_compose exec -T transfer-api sh -c 'find "${STAGING_DIR:-/data/transfer-staging}" "${VERIFIED_DIR:-/data/transfer-verified}" -type f -delete 2>/dev/null; echo "  중계 대기·검사 파일 삭제"'

  echo "== Keycloak 계정 정리"
  if [ -n "$users" ]; then
    printf '%s\n' "$users" | pg_compose exec -T keycloak bash -c '
KC=/opt/keycloak/bin/kcadm.sh
$KC config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "  Keycloak 관리자 로그인 실패"; exit 1; }
n=0
while read -r id; do
  [ -n "$id" ] || continue
  $KC delete "users/$id" -r matchmaking >/dev/null 2>&1 && n=$((n+1))
done
echo "  Keycloak 계정 ${n}개 삭제"'
  fi
  echo "완료. 남은 개수:"
  check
}

case "$MODE" in
  check) check ;;
  apply)
    read -r -p "시험 데이터를 지웁니다 (되돌릴 수 없음). 계속하려면 yes 입력: " ans
    [ "$ans" = "yes" ] || { echo "취소했습니다."; exit 1; }
    apply ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
