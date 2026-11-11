#!/bin/bash
# keycloak-setup 서비스가 시작할 때 한 번 실행한다. (realm 파일은 처음 한 번만 불러오므로 이미 만든 realm 에도 적용)
#  0) 나중에 추가된 직원 계정 보충 (counselor_b, super_admin)
#  1) 한국어 기본, 직원용 로그인 테마(internal-web 만), 토큰 암호화 키 끄기
#  2) 직원 OTP(TOTP) 강제 여부를 .env 의 REQUIRE_STAFF_OTP 에 맞춘다
#   true  (기본, 시연·평가): OTP 미등록 직원에게 첫 로그인 시 OTP 등록 강제
#   false (개발 중에만): 직원의 OTP 등록 요구와 등록된 OTP 를 지워 ID·비밀번호만으로 로그인
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
REALM=matchmaking
STAFF="counselor_a counselor_b data_admin super_admin approver"

$KC config credentials --server http://keycloak:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

# 0) 나중에 추가된 직원이 기존 realm 에 없으면 같은 id 로 추가 (있으면 건너뜀)
#    형식: username|id|이름|성|realm 역할
add_user() {
  IFS='|' read -r uname uid first last role <<<"$1"
  [ -z "$($KC get users -r "$REALM" -q username="$uname" -q exact=true --fields id --format csv --noquotes)" ] || return 0
  cat > /tmp/add-user.json <<JSON
{"ifResourceExists":"SKIP","users":[{"id":"$uid","username":"$uname","enabled":true,
 "email":"$uname@example.test","emailVerified":true,"firstName":"$first","lastName":"$last",
 "credentials":[{"type":"password","value":"${KC_TEST_PASSWORD:?}","temporary":false}],
 "realmRoles":["$role"],"requiredActions":["CONFIGURE_TOTP"]}]}
JSON
  $KC create partialImport -r "$REALM" -f /tmp/add-user.json >/dev/null
  rm -f /tmp/add-user.json
  echo "직원 추가: $uname ($role)"
}
add_user "counselor_b|11111111-1111-4111-8111-111111111104|상담|직원 B|counselor"
add_user "super_admin|11111111-1111-4111-8111-111111111105|총관리자||data_admin"

# 1) 한국어 기본 + internal-web 직원용 로그인 테마
$KC update "realms/$REALM" -s 'displayName=이음 (가상 결혼정보회사)' -s internationalizationEnabled=true -s 'supportedLocales=["ko","en"]' -s defaultLocale=ko
cid=$($KC get clients -r "$REALM" -q clientId=internal-web --fields id --format csv --noquotes)
$KC update "clients/$cid" -r "$REALM" -s 'attributes."login_theme"=privacygate-staff'
echo "한국어 기본, internal-web 로그인 테마: privacygate-staff"

# 1-1) 토큰 암호화용 키(RSA-OAEP, use=enc)는 쓰지 않으므로 끈다.
#      JWKS 에 enc 키가 섞여 있으면 일부 검증 코드(PyJWK.from_dict)가 키 목록 전체를 읽지 못해 모든 토큰을 거부한다.
#      (관리 API 는 providerId 로 거르지 못하므로 키 제공자 목록에서 bash 로 고른다)
enc_ids=$($KC get components -r "$REALM" -q type=org.keycloak.keys.KeyProvider --fields id,providerId --format csv --noquotes \
  | while IFS=, read -r kid prov; do if [ "$prov" = "rsa-enc-generated" ]; then echo "$kid"; fi; done)
for kid in $enc_ids; do
  $KC update "components/$kid" -r "$REALM" -s 'config.enabled=["false"]' -s 'config.active=["false"]'
done
echo "토큰 암호화 키(RSA-OAEP) 끔: JWKS 에는 서명 키만 공개"

# 2) 직원 OTP
for u in $STAFF; do
  id=$($KC get users -r "$REALM" -q username="$u" -q exact=true --fields id --format csv --noquotes)
  [ -n "$id" ] || { echo "사용자 없음: $u"; continue; }
  # keycloak 이미지에는 awk 가 없어 bash 로 OTP 자격증명 id 만 고른다
  otp_ids=$($KC get "users/$id/credentials" -r "$REALM" --fields id,type --format csv --noquotes \
    | while IFS=, read -r cid ctype; do if [ "$ctype" = "otp" ]; then echo "$cid"; fi; done)
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
