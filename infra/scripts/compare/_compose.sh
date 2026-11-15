# 공통: matchmaking-external 오버레이로 실행 중인 스택에 붙는 compose 인자 (source 해서 사용)
PG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PG_EXT="$PG_ROOT/../matchmaking-external"
[ -d "$PG_EXT" ] || { echo "matchmaking-external 폴더를 찾을 수 없습니다: $PG_EXT" >&2; exit 1; }
pg_compose() {
  (cd "$PG_EXT" && docker compose --project-directory ../privacygate --env-file ../privacygate/.env \
     --env-file ./.local/internal-admin.env -f ../privacygate/compose.yaml -f ./compose.external.yaml \
     -f ./compose.member-lifecycle.yaml --profile external "$@")
}
