#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$HOME/.proxc/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Missing $HOME/.proxc/.env"
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

PORT="${1:-}"
SUBDOMAIN="${2:-}"

if [[ -z "$PORT" || -z "$SUBDOMAIN" ]]; then
  echo "Usage: proxc <port> <subdomain>"
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ Invalid local port: $PORT"
  exit 1
fi

if ! [[ "$SUBDOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "❌ Invalid subdomain label: $SUBDOMAIN"
  echo "   Allowed: lowercase letters, numbers, hyphens (no dots, no leading/trailing hyphen)."
  exit 1
fi

if [[ -z "${REGISTER_ENDPOINT:-}" ]]; then
  echo "❌ Missing REGISTER_ENDPOINT in $ENV_FILE"
  exit 1
fi

echo "🔐 Provisioning HTTPS for ${SUBDOMAIN}.${SERVER_ADDRESS}..."
TMP_BODY="$(mktemp)"
set +e
HTTP_STATUS="$(curl -sS -o "$TMP_BODY" -w "%{http_code}" -X POST "$REGISTER_ENDPOINT" \
  --data-urlencode "subdomain=${SUBDOMAIN}" \
  --data-urlencode "authToken=${AUTH_TOKEN}")"
CURL_EXIT="$?"
set -e

if [[ "$CURL_EXIT" -ne 0 ]]; then
  echo "❌ Failed to reach registration API at ${REGISTER_ENDPOINT}"
  rm -f "$TMP_BODY"
  exit 1
fi

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "❌ Registration failed (${HTTP_STATUS})"
  cat "$TMP_BODY"
  rm -f "$TMP_BODY"
  exit 1
fi
rm -f "$TMP_BODY"

mkdir -p ~/.cache/proxc
CFG="$HOME/.cache/proxc/${SUBDOMAIN}.toml"
cat > "$CFG" <<CFG_EOF
serverAddr = "${SERVER_ADDRESS}"
serverPort = ${SERVER_PORT}

auth.method = "token"
auth.token = "${AUTH_TOKEN}"

[[proxies]]
name = "${SUBDOMAIN}"
type = "http"
localIP = "127.0.0.1"
localPort = ${PORT}
subdomain = "${SUBDOMAIN}"
CFG_EOF

echo "🚀 Tunnel started → https://${SUBDOMAIN}.${SERVER_ADDRESS}"
exec "$HOME/.proxc/frpc" -c "$CFG"
