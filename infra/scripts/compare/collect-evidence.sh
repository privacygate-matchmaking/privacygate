#!/usr/bin/env bash
# 한 번의 시연 결과를 증거 폴더 하나로 모은다.
#   ./infra/scripts/compare/collect-evidence.sh baseline 2026-11-16T01:00:00+0900
# 모으는 것: 브라우저 응답 기록(~/Downloads/pg-evidence-*-<모드>*.json, 받은 파일), 감사 로그(DB 2곳 + JSON 파일),
#            실제 파일(관리자 내보내기·중계 파일 기록·저장소 목록), Wazuh 경보(실행 중일 때).
# 결과: privacygate/evidence/<시각>-<모드>/  (Git 제외. 합성 데이터지만 외부 공유 금지)
set -euo pipefail
LABEL="${1:-}"; SINCE_RAW="${2:-}"
[ -n "$LABEL" ] && [ -n "$SINCE_RAW" ] || { echo "사용법: $0 <baseline|enforce> <since 시각, 예 2026-11-16T01:00:00+0900>" >&2; exit 1; }
source "$(dirname "$0")/_compose.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# +0900 → +09:00 (Python fromisoformat 3.10 이하 호환)
SINCE="$(printf '%s' "$SINCE_RAW" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
OUT="$PG_ROOT/evidence/$(date +%Y%m%d-%H%M%S)-$LABEL"; mkdir -p "$OUT"
echo "$SINCE" > "$OUT/since.txt"

db() { pg_compose exec -T "$1" psql -U db_owner -d "$2" -v ON_ERROR_STOP=1 -q -c "$3"; }
echo "▶ 감사 로그 (DB)"
db business-db matchmaking_business "COPY (SELECT ts,trace_id,actor,role,action,target_type,target_id,result,reason FROM audit_log WHERE ts >= '$SINCE' ORDER BY ts) TO STDOUT WITH CSV HEADER" > "$OUT/audit-internal.csv"
db transfer-db matchmaking_transfer "COPY (SELECT ts,trace_id,actor,role,action,target_type,target_id,result,reason FROM audit_log WHERE ts >= '$SINCE' ORDER BY ts) TO STDOUT WITH CSV HEADER" > "$OUT/audit-transfer.csv"
echo "▶ 감사 로그 (JSON 파일)"
pg_compose exec -T transfer-api python - "$SINCE" < "$HERE/filter_audit_json.py" > "$OUT/audit-json.jsonl" || echo "(JSON 감사 로그 수집 실패)" > "$OUT/audit-json.jsonl"
echo "▶ 실제 파일 기록"
db business-db matchmaking_business "COPY (SELECT e.export_id,u.pseudo_id AS created_by,u.role,e.row_count,e.file_hash,e.transfer_file_id,e.created_at FROM member_exports e JOIN users u ON u.user_id=e.created_by WHERE e.created_at >= '$SINCE' ORDER BY e.created_at) TO STDOUT WITH CSV HEADER" > "$OUT/member-exports.csv"
db transfer-db matchmaking_transfer "COPY (SELECT file_id,file_hash,scan_status,scan_reason,export_banned,created_at FROM transfer_files ORDER BY created_at) TO STDOUT WITH CSV HEADER" > "$OUT/transfer-files.csv"
db transfer-db matchmaking_transfer "COPY (SELECT d.delivery_id,d.downloaded_at,a.approved_file_id,r.request_status,r.purpose FROM deliveries d JOIN approvals a ON a.approval_id=d.approval_id JOIN export_requests r ON r.request_id=a.request_id ORDER BY d.created_at) TO STDOUT WITH CSV HEADER" > "$OUT/deliveries.csv"
pg_compose exec -T transfer-api sh -c 'echo "[staging]"; ls -l /data/transfer-staging; echo "[verified]"; ls -l /data/transfer-verified' > "$OUT/transfer-storage.txt" 2>&1 || true
echo "▶ Wazuh 경보"
if docker ps --format '{{.Names}}' | grep -q '^ieum-wazuh-wazuh.manager-1$'; then
  sleep 5   # 수집 지연 여유
  docker exec -i ieum-wazuh-wazuh.manager-1 /var/ossec/framework/python/bin/python3 - "$SINCE" < "$HERE/filter_wazuh.py" > "$OUT/wazuh-alerts.jsonl" || echo '{"error":"wazuh 수집 실패"}' > "$OUT/wazuh-alerts.jsonl"
else
  echo '{"error":"Wazuh 미실행 (ieum-wazuh-wazuh.manager-1 없음)"}' > "$OUT/wazuh-alerts.jsonl"
fi
echo "▶ 브라우저 응답 기록"
moved=0
for f in "$HOME"/Downloads/pg-evidence-*-"$LABEL"*; do [ -e "$f" ] || continue; mv "$f" "$OUT/"; moved=$((moved+1)); done
echo "   옮긴 파일 ${moved}개"
echo "✔ 완료: $OUT"
ls -1 "$OUT"
