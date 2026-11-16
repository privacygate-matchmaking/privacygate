#!/bin/bash
# Tailscale Funnel 공개/중지 (컴퓨터 1 = Mac 에서 실행). 자세한 순서는 infra/funnel/README.md
#
#   ./infra/scripts/funnel.sh urls     .env 에 넣을 주소 4개 출력
#   ./infra/scripts/funnel.sh up       공개 시작 (인터넷: 회원 화면·회원 로그인 / tailnet 전용: 직원 화면·Keycloak 관리·Wazuh)
#   ./infra/scripts/funnel.sh status   현재 공개 상태
#   ./infra/scripts/funnel.sh down     모두 중지 (시연이 끝나면 반드시)
#
# 공개 범위
#   인터넷(Funnel)  :443  → 127.0.0.1:8090 external-web (회원 화면)
#                   :8443 → 127.0.0.1:8088 auth-gateway → Keycloak /realms/matchmaking, /resources 만
#   tailnet(serve)  :8080 → 127.0.0.1:8080 internal-web (직원 화면)
#                   :8081 → 127.0.0.1:8081 Keycloak 관리자 화면
#                   :8444 → 127.0.0.1:8444 Wazuh 대시보드 (Wazuh 를 켰을 때)
set -euo pipefail

TS="${TAILSCALE:-}"
if [ -z "$TS" ]; then
  if command -v tailscale >/dev/null 2>&1; then TS=tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  else echo "tailscale 명령을 찾지 못했습니다. Tailscale 을 설치하고 로그인하세요." >&2; exit 1; fi
fi

host() {
  "$TS" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
}

case "${1:-}" in
  urls)
    h=$(host)
    cat <<EOF
# privacygate/.env 에 아래 4줄을 넣거나 바꾸세요 (값은 공유하지 않아도 되는 공개 주소)
KC_PUBLIC_URL=https://$h:8443
KC_ADMIN_URL=https://$h:8081
INTERNAL_BASE_URL=https://$h:8080
EXTERNAL_BASE_URL=https://$h
EOF
    ;;
  up)
    h=$(host)
    # 인터넷 공개 (Funnel 은 443·8443·10000 만 가능)
    "$TS" funnel --bg --https=443  https+insecure://127.0.0.1:8090
    "$TS" funnel --bg --https=8443 http://127.0.0.1:8088
    # tailnet 전용 (Tailscale 에 로그인한 팀원 기기만)
    "$TS" serve  --bg --https=8080 https+insecure://127.0.0.1:8080
    "$TS" serve  --bg --https=8081 https+insecure://127.0.0.1:8081
    "$TS" serve  --bg --https=8444 https+insecure://127.0.0.1:8444
    echo
    echo "인터넷 공개   회원 화면   https://$h"
    echo "             회원 로그인 https://$h:8443/realms/matchmaking/"
    echo "tailnet 전용  직원 화면   https://$h:8080"
    echo "             Keycloak 관리 https://$h:8081/admin/"
    echo "             Wazuh       https://$h:8444"
    echo
    "$TS" funnel status
    ;;
  status)
    "$TS" funnel status
    ;;
  down)
    "$TS" funnel reset || true
    "$TS" serve reset || true
    echo "Funnel·serve 를 모두 껐습니다. (Docker 서비스는 그대로)"
    ;;
  *)
    sed -n '2,8p' "$0"; exit 1 ;;
esac
