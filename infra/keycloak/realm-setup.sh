#!/bin/bash
# keycloak-setup 서비스가 시작할 때 한 번 실행한다. (realm 파일은 처음 한 번만 불러오므로 이미 만든 realm 에도 적용)
#  0) 나중에 추가된 직원 계정 보충 (counselor_b)
#  1) 한국어 기본, 직원용 로그인 테마(internal-web 만), 토큰 암호화 키 끄기
#  2) OTP 는 쓰지 않는다: 이전 설정으로 남은 직원의 OTP 등록 요구·등록된 OTP 를 지운다 (ID·비밀번호 로그인)
#  3) internal-admin client: internal-api 가 탈퇴 확정 회원의 Keycloak 세션 종료·계정 삭제에만 쓰는 service account
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
REALM=matchmaking
STAFF="counselor_a counselor_b data_admin approver"

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
 "realmRoles":["$role"]}]}
JSON
  $KC create partialImport -r "$REALM" -f /tmp/add-user.json >/dev/null
  rm -f /tmp/add-user.json
  echo "직원 추가: $uname ($role)"
}
add_user "counselor_b|11111111-1111-4111-8111-111111111104|상담|직원 B|counselor"

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

# 2) OTP 사용 안 함: 남아 있는 OTP 등록 요구·OTP 자격증명 정리
for u in $STAFF; do
  id=$($KC get users -r "$REALM" -q username="$u" -q exact=true --fields id --format csv --noquotes)
  [ -n "$id" ] || { echo "사용자 없음: $u"; continue; }
  # keycloak 이미지에는 awk 가 없어 bash 로 OTP 자격증명 id 만 고른다
  otp_ids=$($KC get "users/$id/credentials" -r "$REALM" --fields id,type --format csv --noquotes \
    | while IFS=, read -r cid ctype; do if [ "$ctype" = "otp" ]; then echo "$cid"; fi; done)
  $KC update "users/$id" -r "$REALM" -s 'requiredActions=[]'
  for c in $otp_ids; do $KC delete "users/$id/credentials/$c" -r "$REALM"; done
done
echo "직원 로그인: ID·비밀번호 (OTP 사용 안 함)"

# 3) 탈퇴 회원 계정 정리용 client (브라우저 로그인 불가, client credentials 만)
#    권한: realm-management 의 view-users·manage-users. 직원 계정은 지우지 않도록 internal-api 가 역할을 확인한 뒤 삭제한다.
#    secret 은 .env 의 INTERNAL_ADMIN_CLIENT_SECRET (매 실행 때 맞춘다)
aid=$($KC get clients -r "$REALM" -q clientId=internal-admin --fields id --format csv --noquotes)
if [ -z "$aid" ]; then
  $KC create clients -r "$REALM" -s clientId=internal-admin -s 'name=internal-api 회원 계정 정리' -s enabled=true \
    -s publicClient=false -s clientAuthenticatorType=client-secret -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false -s implicitFlowEnabled=false -s directAccessGrantsEnabled=false \
    -s "secret=${INTERNAL_ADMIN_CLIENT_SECRET:?}" >/dev/null
  aid=$($KC get clients -r "$REALM" -q clientId=internal-admin --fields id --format csv --noquotes)
fi
$KC update "clients/$aid" -r "$REALM" -s "secret=${INTERNAL_ADMIN_CLIENT_SECRET:?}" -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s directAccessGrantsEnabled=false
$KC add-roles -r "$REALM" --uusername service-account-internal-admin --cclientid realm-management \
  --rolename view-users --rolename manage-users
echo "internal-admin client: 탈퇴 회원 Keycloak 계정 정리용 (view-users, manage-users)"
