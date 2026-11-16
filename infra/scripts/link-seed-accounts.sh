#!/bin/bash
# [시험 전용] 시드 회원 A-001~A-020 중 로그인 계정이 없는 회원에게 member_001~member_020 계정을 만들어 연결한다.
# 계정 UUID 는 팀원 환경(matchmaking-external/infra/lab/internal20-account-plan.json)과 같다.
# 이미 계정이 연결된 회원(member_b = A-003 등)은 건드리지 않는다. 비밀번호는 KC_TEST_PASSWORD (화면에 출력하지 않음).
#
#   ./infra/scripts/link-seed-accounts.sh check    연결 안 된 시드 회원 보기 (변경 없음)
#   ./infra/scripts/link-seed-accounts.sh apply    계정 만들기 + 업무 DB 연결
set -euo pipefail
source "$(dirname "$0")/compare/_compose.sh"
MODE="${1:-check}"

bdb() { pg_compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 -At "$@"; }

# 회원 코드 → 로그인 UUID (A-001·002·004 는 기존 member_c·d·e 의 UUID, A-003 은 member_b)
uid_for() {
  local n=$((10#$1))
  case "$n" in 1) s=202 ;; 2) s=203 ;; 3) s=201 ;; 4) s=204 ;; *) s=$((200 + n)) ;; esac
  printf '22222222-2222-4222-8222-222222222%03d' "$s"
}

pending() {
  # 결과: <번호>|<성별>  (로그인 계정이 없는 활동 중 시드 회원)
  bdb -c "SELECT substr(pseudo_id,3), coalesce(gender,'-') FROM members
           WHERE pseudo_id ~ '^A-0(0[1-9]|1[0-9]|20)$' AND user_id IS NULL AND status = 'active'
             AND NOT EXISTS (SELECT 1 FROM users u WHERE u.pseudo_id = members.pseudo_id) ORDER BY pseudo_id"
}

check() {
  echo "== 로그인 계정이 없는 시드 회원"
  local rows; rows=$(pending)
  if [ -z "$rows" ]; then echo "  없음 (모두 연결됨)"; return; fi
  printf '%s\n' "$rows" | while IFS='|' read -r n g; do echo "  A-$n ($g) → member_$n"; done
}

apply() {
  local rows; rows=$(pending)
  if [ -z "$rows" ]; then echo "모든 시드 회원이 이미 연결돼 있습니다."; return; fi
  local list=""
  while IFS='|' read -r n g; do list="$list$n $(uid_for "$n")"$'\n'; done <<<"$rows"

  echo "== Keycloak 계정 만들기"
  ok=$(printf '%s' "$list" | pg_compose exec -T keycloak bash -c '
KC=/opt/keycloak/bin/kcadm.sh
$KC config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "ERR Keycloak 관리자 로그인 실패" >&2; exit 1; }
while read -r n uid; do
  [ -n "$n" ] || continue
  name="member_$n"
  owner=$($KC get users -r matchmaking -q username="$name" -q exact=true --fields id --format csv --noquotes 2>/dev/null)
  if [ -n "$owner" ] && [ "$owner" != "$uid" ]; then echo "  건너뜀: $name 이름을 다른 계정이 사용 중" >&2; continue; fi
  if ! $KC get "users/$uid" -r matchmaking >/dev/null 2>&1; then
    printf "{\"ifResourceExists\":\"SKIP\",\"users\":[{\"id\":\"%s\",\"username\":\"%s\",\"enabled\":true,\"email\":\"%s@example.test\",\"emailVerified\":true,\"firstName\":\"Synthetic\",\"lastName\":\"%s\",\"credentials\":[{\"type\":\"password\",\"value\":\"%s\",\"temporary\":false}],\"realmRoles\":[\"member\"]}]}" \
      "$uid" "$name" "$name" "$name" "$KC_TEST_PASSWORD" > /tmp/seed-user.json
    $KC create partialImport -r matchmaking -f /tmp/seed-user.json >/dev/null 2>&1 || { rm -f /tmp/seed-user.json; echo "  실패: $name" >&2; continue; }
    rm -f /tmp/seed-user.json
  else
    uname=$($KC get "users/$uid" -r matchmaking --fields username --format csv --noquotes 2>/dev/null)
    [ "$uname" = "$name" ] || { echo "  건너뜀: $uid 는 이미 $uname 계정" >&2; continue; }
    $KC add-roles -r matchmaking --uid "$uid" --rolename member >/dev/null 2>&1 || true
  fi
  echo "$n $uid"
done')
  [ -n "$ok" ] || { echo "만든 계정이 없습니다."; return; }
  printf '%s\n' "$ok" | while read -r n uid; do echo "  member_$n 준비됨"; done

  echo "== 업무 DB 연결"
  sql="BEGIN;"
  while read -r n uid; do
    [ -n "$n" ] || continue
    sql="$sql
INSERT INTO users (user_id, pseudo_id, display_name, role)
SELECT '$uid', 'A-$n', 'member_$n', 'member'
 WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = '$uid' OR pseudo_id = 'A-$n');
UPDATE members m SET user_id = '$uid'
 WHERE m.pseudo_id = 'A-$n' AND m.user_id IS NULL
   AND EXISTS (SELECT 1 FROM users u WHERE u.user_id = '$uid' AND u.pseudo_id = 'A-$n' AND u.role = 'member');"
  done <<<"$ok"
  sql="$sql
SELECT '  ' || m.pseudo_id || ' (' || coalesce(m.gender,'-') || ') ↔ ' || u.display_name
  FROM members m JOIN users u ON u.user_id = m.user_id
 WHERE m.pseudo_id ~ '^A-0(0[1-9]|1[0-9]|20)$' ORDER BY m.pseudo_id;
COMMIT;"
  printf '%s\n' "$sql" | bdb | grep -v '^BEGIN$\|^COMMIT$\|^INSERT\|^UPDATE'
  echo "완료. 비밀번호는 다른 시험 계정과 같은 KC_TEST_PASSWORD 입니다."
}

case "$MODE" in
  check) check ;;
  apply) apply ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
