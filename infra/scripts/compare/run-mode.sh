#!/usr/bin/env bash
# 비교 시연 모드 전환: internal-api · transfer-api · external-api 만 GATE_MODE 를 바꿔 다시 띄운다.
#   ./infra/scripts/compare/run-mode.sh baseline   # 취약 비교 버전 (공격 ①② 대상 통제 2개만 꺼짐)
#   ./infra/scripts/compare/run-mode.sh enforce    # 보안 적용 버전 (기본)
# .env 는 읽거나 고치지 않는다 (쉘 환경변수가 compose 치환에서 우선). 시연이 끝나면 반드시 enforce 로 되돌린다.
set -euo pipefail
MODE="${1:-}"
case "$MODE" in baseline|enforce) ;; *) echo "사용법: $0 baseline|enforce" >&2; exit 1;; esac
source "$(dirname "$0")/_compose.sh"
GATE_MODE="$MODE" pg_compose up -d --no-deps --force-recreate internal-api transfer-api external-api
pg_compose restart internal-web external-web >/dev/null   # nginx 가 새 컨테이너 주소를 다시 찾도록
for s in internal-api transfer-api external-api; do
  for i in $(seq 1 20); do v=$(pg_compose exec -T "$s" printenv GATE_MODE 2>/dev/null || true); [ -n "$v" ] && break; sleep 1; done
  printf '%-13s GATE_MODE=%s\n' "$s" "${v:-확인 실패}"
  [ "$v" = "$MODE" ] || { echo "⚠️  $s 모드가 $MODE 가 아닙니다" >&2; exit 1; }
done
echo "since 기준 시각(이 값을 collect-evidence.sh 에 넘기세요): $(date '+%Y-%m-%dT%H:%M:%S%z')"
