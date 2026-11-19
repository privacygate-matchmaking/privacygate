#!/usr/bin/env bash
# 서비스 간 mTLS 확인: external-api → transfer-api, transfer-api → internal-api, internal-api → transfer-api.
# 각 경로에서 "내 인증서로는 연결, 인증서 없이·평문 HTTP 는 차단" 이 나와야 한다. (compose.mtls.yaml 을 켠 상태)
set -euo pipefail
source "$(dirname "$0")/compare/_compose.sh"
PY="$(dirname "$0")/mtls-check.py"
echo "== external-api 에서";  pg_compose exec -T external-api python - transfer-api < "$PY" || true
echo "== transfer-api 에서";  pg_compose exec -T transfer-api python - internal-api < "$PY" || true
echo "== internal-api 에서";  pg_compose exec -T internal-api python - transfer-api < "$PY" || true
