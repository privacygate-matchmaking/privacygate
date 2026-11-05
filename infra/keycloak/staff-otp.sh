#!/bin/bash
# 직원 OTP(TOTP) 강제 여부를 .env 의 REQUIRE_STAFF_OTP 에 맞춘다. (keycloak-setup 서비스가 시작할 때 한 번 실행)
#   true  (기본, 시연·평가): OTP 미등록 직원에게 첫 로그인 시 OTP 등록 강제
#   false (개발 중에만): 직원의 OTP 등록 요구와 등록된 OTP 를 지워 ID·비밀번호만으로 로그인
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
REALM=matchmaking
STAFF="counselor_a data_admin approver"

$KC config credentials --server http://keycloak:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

for u in $STAFF; do
  id=$($KC get users -r "$REALM" -q username="$u" -q exact=true --fields id --format csv --noquotes)
  [ -n "$id" ] || { echo "사용자 없음: $u"; continue; }
  otp_ids=$($KC get "users/$id/credentials" -r "$REALM" --fields id,type --format csv --noquotes | awk -F, '$2=="otp"{print $1}')
  if [ "${REQUIRE_STAFF_OTP:-true}" = "false" ]; then
    $KC update "users/$id" -r "$REALM" -s 'requiredActions=[]'
    for c in $otp_ids; do $KC delete "users/$id/credentials/$c" -r "$REALM"; done
    echo "[개발 모드] $u: OTP 끔"
  elif [ -z "$otp_ids" ]; then
    $KC update "users/$id" -r "$REALM" -s 'requiredActions=["CONFIGURE_TOTP"]'
    echo "$u: 첫 로그인 시 OTP 등록 필요"
  else
    echo "$u: OTP 등록됨"
  fi
done
