#!/usr/bin/env bash
# 서비스 간 mTLS 인증서 만들기 (사설 CA 1개 + 서비스별 인증서). Git 에 넣지 않는다 (infra/secrets 는 .gitignore).
#   ./infra/scripts/mtls-certs.sh          # 없으면 만든다 (있으면 그대로)
#   ./infra/scripts/mtls-certs.sh rotate   # CA·인증서 전부 새로 만든다 (키 교체) → 이후 해당 서비스 재시작
#   ./infra/scripts/mtls-certs.sh enable   # 보조 스크립트(reset·비교 시연 등)가 compose.mtls.yaml 을 함께 쓰도록 표시
#   ./infra/scripts/mtls-certs.sh disable  # 표시 해제 (mTLS 끔)
# 인증서: internal-api·transfer-api(서버+클라이언트), external-api·internal-web(클라이언트). 유효기간 1년.
# 파일 권한은 증빙 키와 같다: 상위 폴더 700, 파일 644 (컨테이너 앱 계정이 읽음). CA 개인키는 600 으로 컨테이너에 넣지 않는다.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=infra/secrets/mtls
SERVICES="internal-api transfer-api external-api internal-web"

case "${1:-}" in
  enable)  [ -f "$DIR/ca.pem" ] || { echo "먼저 인증서를 만드세요: $0"; exit 1; }
           touch "$DIR/enabled"; echo "mTLS 표시 켬 (composeArgs 에도 -f ../privacygate/compose.mtls.yaml 추가)"; exit 0 ;;
  disable) rm -f "$DIR/enabled"; echo "mTLS 표시 끔 (composeArgs 에서도 compose.mtls.yaml 빼기)"; exit 0 ;;
esac
if [ "${1:-}" = "rotate" ]; then
  echo "기존 mTLS 인증서를 지우고 새로 만듭니다."
  was_on=0; [ -f "$DIR/enabled" ] && was_on=1
  rm -rf "$DIR"
elif [ -f "$DIR/ca.pem" ]; then
  echo "이미 있습니다: $DIR (새로 만들려면: $0 rotate)"
  for s in $SERVICES; do openssl x509 -in "$DIR/$s.pem" -noout -subject -enddate | tr '\n' ' '; echo; done
  exit 0
fi
mkdir -p "$DIR"; chmod 700 infra/secrets "$DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# macOS 기본 openssl(LibreSSL)에서도 되도록 -addext 대신 설정 파일을 쓴다
cat > "$TMP/ca.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3_ca
prompt=no
[dn]
CN=PrivacyGate internal service CA
[v3_ca]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
CNF
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 730 -config "$TMP/ca.cnf" \
  -keyout "$DIR/ca.key" -out "$DIR/ca.pem" 2>/dev/null
chmod 600 "$DIR/ca.key"; chmod 644 "$DIR/ca.pem"

for s in $SERVICES; do
  cat > "$TMP/$s.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:$s,DNS:localhost
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$s/OU=privacygate-service" -keyout "$DIR/$s.key" -out "$TMP/$s.csr" 2>/dev/null
  openssl x509 -req -in "$TMP/$s.csr" -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" -CAcreateserial -days 365 -sha256 \
    -extfile "$TMP/$s.ext" -out "$DIR/$s.pem" 2>/dev/null
  chmod 644 "$DIR/$s.key" "$DIR/$s.pem"
  echo "  $s 인증서 생성"
done
rm -f "$DIR/ca.srl"
[ "${was_on:-0}" = 1 ] && touch "$DIR/enabled"
echo "완료: $DIR  (mTLS 를 켜려면 composeArgs 에 -f ../privacygate/compose.mtls.yaml 추가)"
