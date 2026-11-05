#!/usr/bin/env bash
# .env 와 infra/secrets/evidence_master.key 를 무작위 값으로 만든다.
# 이미 있으면 덮어쓰지 않는다. 두 파일 모두 .gitignore 대상이다.
set -euo pipefail
cd "$(dirname "$0")/../.."      # privacygate 레포 루트

rand() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-32; }

if [ -f .env ]; then
  echo ".env 가 이미 있습니다. 새로 만들려면 지우고 다시 실행하세요."
else
  sed \
    -e "s|^KC_BOOTSTRAP_ADMIN_PASSWORD=.*|KC_BOOTSTRAP_ADMIN_PASSWORD=$(rand)|" \
    -e "s|^KC_TEST_PASSWORD=.*|KC_TEST_PASSWORD=Test-$(rand | cut -c1-12)|" \
    -e "s|^INTERNAL_WEB_CLIENT_SECRET=.*|INTERNAL_WEB_CLIENT_SECRET=$(rand)|" \
    -e "s|^EXTERNAL_WEB_CLIENT_SECRET=.*|EXTERNAL_WEB_CLIENT_SECRET=$(rand)|" \
    -e "s|^TRANSFER_API_CLIENT_SECRET=.*|TRANSFER_API_CLIENT_SECRET=$(rand)|" \
    -e "s|^EXTERNAL_API_CLIENT_SECRET=.*|EXTERNAL_API_CLIENT_SECRET=$(rand)|" \
    -e "s|^BUSINESS_DB_OWNER_PASSWORD=.*|BUSINESS_DB_OWNER_PASSWORD=$(rand)|" \
    -e "s|^BUSINESS_DB_APP_PASSWORD=.*|BUSINESS_DB_APP_PASSWORD=$(rand)|" \
    -e "s|^TRANSFER_DB_OWNER_PASSWORD=.*|TRANSFER_DB_OWNER_PASSWORD=$(rand)|" \
    -e "s|^TRANSFER_DB_APP_PASSWORD=.*|TRANSFER_DB_APP_PASSWORD=$(rand)|" \
    .env.example > .env
  chmod 600 .env
  echo ".env 생성 완료 (시험 계정 비밀번호: .env 의 KC_TEST_PASSWORD)"
fi

mkdir -p infra/secrets
chmod 700 infra/secrets
if [ -f infra/secrets/evidence_master.key ]; then
  echo "infra/secrets/evidence_master.key 가 이미 있습니다."
else
  openssl rand -base64 32 > infra/secrets/evidence_master.key
  chmod 644 infra/secrets/evidence_master.key   # 컨테이너 앱 계정(uid 10001)이 읽음. 상위 폴더 700
  echo "infra/secrets/evidence_master.key 생성 완료"
fi

# ---------- HTTPS 인증서 (localhost 용, Git 제외) ----------
TLS=infra/secrets/tls
mkdir -p "$TLS"
chmod 755 "$TLS"   # 컨테이너(nginx 101, keycloak 1000)가 읽음. 상위 infra/secrets 는 700
if [ -f "$TLS/cert.pem" ]; then
  echo "$TLS/cert.pem 이 이미 있습니다."
elif command -v mkcert >/dev/null 2>&1; then
  # mkcert: 내 PC 가 신뢰하는 로컬 CA 로 발급 → 브라우저 경고 없음 (처음 한 번 `mkcert -install`)
  mkcert -cert-file "$TLS/cert.pem" -key-file "$TLS/key.pem" localhost 127.0.0.1 ::1
  echo "mkcert 로 HTTPS 인증서 생성 완료"
else
  # mkcert 가 없으면 자체 서명 인증서 (브라우저에서 한 번 '계속 진행' 필요)
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout "$TLS/key.pem" -out "$TLS/cert.pem" 2>/dev/null
  echo "자체 서명 HTTPS 인증서 생성 완료 (경고 없이 쓰려면 mkcert 설치 후 $TLS 를 지우고 다시 실행)"
fi
chmod 644 "$TLS/cert.pem" "$TLS/key.pem"
