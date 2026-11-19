#!/usr/bin/env bash
# 감사 로그 위변조 검사 (해시 체인). 결과는 화면 + audit-verifier.json(→ Wazuh 100160·100161).
#   ./infra/scripts/audit-verify.sh            # 체인 검사
#   AUDIT_IDLE_HOURS=24 ./infra/scripts/audit-verify.sh   # + 24시간 넘게 기록이 없으면 '수집 중단 의심'
# 감사 파일은 서비스별 계정으로 0640 생성되므로 root 로 읽는다. 파일을 고치지 않는다(결과 한 줄 추가만).
set -euo pipefail
source "$(dirname "$0")/compare/_compose.sh"
pg_compose exec -T -u 0 -e AUDIT_IDLE_HOURS="${AUDIT_IDLE_HOURS:-0}" internal-api python - < "$(dirname "$0")/audit-verify.py"
