# 공통: matchmaking-external 오버레이로 실행 중인 스택에 붙는 compose 인자 (source 해서 사용)
PG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PG_EXT="$PG_ROOT/../matchmaking-external"
[ -d "$PG_EXT" ] || { echo "matchmaking-external 폴더를 찾을 수 없습니다: $PG_EXT" >&2; exit 1; }
# Tailscale Funnel 배포(.env 에 KC_ADMIN_URL 이 있음)면 compose.funnel.yaml 도 붙인다 (infra/funnel/README.md)
# (macOS 기본 bash 3.2 는 set -u 에서 빈 배열 "${a[@]}" 를 오류로 보므로 ${a[@]+"${a[@]}"} 형태로 쓴다)
PG_FUNNEL=()
grep -q '^KC_ADMIN_URL=' "$PG_ROOT/.env" 2>/dev/null && PG_FUNNEL=(-f ../privacygate/compose.funnel.yaml)
# 서비스 간 mTLS 를 켰으면(infra/secrets/mtls/enabled 가 있음, mtls-certs.sh enable) compose.mtls.yaml 도 붙인다
PG_MTLS=()
[ -f "$PG_ROOT/infra/secrets/mtls/enabled" ] && PG_MTLS=(-f ../privacygate/compose.mtls.yaml)
pg_compose() {
  (cd "$PG_EXT" && docker compose --project-directory ../privacygate --env-file ../privacygate/.env \
     --env-file ./.local/internal-admin.env -f ../privacygate/compose.yaml ${PG_FUNNEL[@]+"${PG_FUNNEL[@]}"} -f ./compose.external.yaml \
     -f ./compose.member-lifecycle.yaml ${PG_MTLS[@]+"${PG_MTLS[@]}"} --profile external "$@")
}
