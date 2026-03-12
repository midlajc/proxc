#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0"
}

case "${1:-}" in
    "")
        ;;
    -server)
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

if (( "$#" > 0 )); then
    usage
    exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Server uninstall must run as root (use sudo)."
    exit 1
fi

INSTALL_DIR="/opt/frp"
BASE_DOMAIN=""
REGISTER_ENV_FILE="${INSTALL_DIR}/register.env"

if [[ -f "$REGISTER_ENV_FILE" ]]; then
    BASE_DOMAIN="$(sed -n 's/^BASE_DOMAIN=//p' "$REGISTER_ENV_FILE" | head -n 1)"
fi

echo "Uninstalling FRP server..."

systemctl stop frps.service || true
systemctl disable frps.service || true
rm -f /etc/systemd/system/frps.service

systemctl stop proxc-register.service || true
systemctl disable proxc-register.service || true
rm -f /etc/systemd/system/proxc-register.service

systemctl daemon-reload

rm -rf "$INSTALL_DIR"
rm -f /etc/nginx/sites-available/proxc
rm -f /etc/nginx/sites-enabled/proxc
rm -f /etc/nginx/sites-available/proxc-*.conf
rm -f /etc/nginx/sites-enabled/proxc-*.conf
rm -f /etc/nginx/conf.d/proxc*.conf
if [[ -n "$BASE_DOMAIN" ]]; then
    rm -f /etc/nginx/sites-available/proxc-*."$BASE_DOMAIN".conf
    rm -f /etc/nginx/sites-enabled/proxc-*."$BASE_DOMAIN".conf
fi
rm -f /etc/letsencrypt/renewal-hooks/deploy/proxc-nginx-reload.sh
rm -rf /var/www/proxc-acme

if command -v nginx >/dev/null 2>&1; then
    nginx -t
    systemctl reload nginx || true
fi

echo "FRP server uninstalled."
