#!/bin/sh
# 합성 증빙 만들기 (시험용): 회원의 이름·생년월일·성별로 신분증·혼인관계·소득·부동산·학력·재직 PDF 6종 + 프로필 사진.
# 발급번호는 업무 DB 합성 발급대장(doc_registry)과 맞아 자동 검사에서 "진위 확인"이 나온다.
# 실제 기관 양식이 아닌 '이음 시험용' 문서이며 실제 개인정보를 넣지 않는다.
#
# 사용 (privacygate 폴더, 내부 스택 실행 중):
#   ./infra/scripts/make-sample-evidence.sh A-003                 → ./samples/A-003_*.pdf, A-003_photo.jpg
#   ./infra/scripts/make-sample-evidence.sh A-003 ./samples 72000000 이혼 경기도
#     (선택: 출력 폴더, 연소득(원), 혼인상태 미혼|이혼|사별, 부동산 시·도 또는 none)
set -eu
cd "$(dirname "$0")/../.."
code="${1:?회원 코드(A-003 형식)를 입력하세요}"
out="${2:-./samples}"
income="${3:-52000000}"
marital="${4:-미혼}"
property="${5:-서울특별시}"
echo "$code" | grep -Eq '^[A-Z]-[0-9]{3}$' || { echo "회원 코드 형식이 아닙니다: $code" >&2; exit 1; }
echo "$income" | grep -Eq '^[0-9]{1,12}$' || { echo "연소득은 숫자(원)로 입력하세요" >&2; exit 1; }

row=$(docker compose exec -T business-db psql -U db_owner -d matchmaking_business -tA -F'|' \
      -c "SELECT name, birth_date, gender FROM members WHERE pseudo_id = '$code'")
[ -n "$row" ] || { echo "회원을 찾을 수 없습니다: $code" >&2; exit 1; }
name=$(echo "$row" | cut -d'|' -f1)
birth=$(echo "$row" | cut -d'|' -f2)
gender=$(echo "$row" | cut -d'|' -f3)

mkdir -p "$out"
abs=$(cd "$out" && pwd)
docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" -v "$abs:/out" doc-inspector \
  python -m inspector.samples --out /out --code "$code" --name "$name" --birth "$birth" --gender "$gender" \
  --income "$income" --marital "$marital" --property "$property"
ls -1 "$abs" | grep "^$code"
