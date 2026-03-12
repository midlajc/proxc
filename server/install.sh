#!/usr/bin/env bash
set -euo pipefail

FRP_VERSION="0.52.3"
REGISTER_PORT="7090"
ACME_WEBROOT="/var/www/proxc-acme"
PROXC_ASSET_BASE_URL="${PROXC_ASSET_BASE_URL:-https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/server}"

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
    echo "❌ Server install must run as root (use sudo)."
    exit 1
fi

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi

LOCAL_ASSET_DIR="${PROXC_LOCAL_ASSET_DIR:-}"
if [[ -z "$LOCAL_ASSET_DIR" && -n "$SCRIPT_DIR" && ( -d "$SCRIPT_DIR/installer_assets" || -d "$SCRIPT_DIR/templates" ) ]]; then
    LOCAL_ASSET_DIR="$SCRIPT_DIR"
fi

INSTALL_DIR="/opt/frp"
ASSET_TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$ASSET_TMP_DIR"
}
trap cleanup EXIT

download_url() {
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
        return
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
        return
    fi

    echo "❌ Missing downloader. Install curl or wget."
    exit 1
}

download_asset() {
    local asset_name="$1"
    local destination="$2"
    local remote_url

    if [[ -n "$LOCAL_ASSET_DIR" ]]; then
        if [[ -f "$LOCAL_ASSET_DIR/$asset_name" ]]; then
            cp "$LOCAL_ASSET_DIR/$asset_name" "$destination"
            return
        fi

        if [[ -f "$LOCAL_ASSET_DIR/server/$asset_name" ]]; then
            cp "$LOCAL_ASSET_DIR/server/$asset_name" "$destination"
            return
        fi
    fi

    remote_url="${PROXC_ASSET_BASE_URL%/}/$asset_name"
    if download_url "$remote_url" "$destination"; then
        return
    fi

    if [[ "${PROXC_ASSET_BASE_URL%/}" != */server ]]; then
        remote_url="${PROXC_ASSET_BASE_URL%/}/server/$asset_name"
        if download_url "$remote_url" "$destination"; then
            return
        fi
    fi

    echo "❌ Failed to download asset: $asset_name"
    exit 1
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[|&]/\\&/g'
}

render_template() {
    local template_path="$1"
    local output_path="$2"
    shift 2

    local sed_args=()
    local key value escaped_value
    while (( "$#" )); do
        key="$1"
        value="$2"
        shift 2
        escaped_value="$(escape_sed_replacement "$value")"
        sed_args+=("-e" "s|__${key}__|${escaped_value}|g")
    done

    sed "${sed_args[@]}" "$template_path" > "$output_path"
}

if [[ -z "${SERVER_ADDRESS:-}" ]]; then
    read -p "Enter server address (base domain): " SERVER_ADDRESS </dev/tty
fi

if [[ -z "${SERVER_PORT:-}" ]]; then
    read -p "Enter server port [7000]: " SERVER_PORT </dev/tty
fi
SERVER_PORT="${SERVER_PORT:-7000}"

if [[ -z "${AUTH_TOKEN:-}" ]]; then
    read -p "Enter auth token (leave blank for none): " AUTH_TOKEN </dev/tty
fi

if [[ -z "${CERT_EMAIL:-}" ]]; then
    read -p "Enter Certbot email: " CERT_EMAIL </dev/tty
fi

echo "Make sure to expose ports ${SERVER_PORT}, 80 and 443 in your firewall or cloud provider settings."
echo "Installing nginx and certbot..."
apt update
apt install -y nginx certbot python3 python3-certbot-nginx curl

get_frps() {
    local uname_out arch archive
    uname_out="$(uname -s)"
    arch="$(uname -m)"

    if [[ "$uname_out" != "Linux" ]]; then
        echo "❌ Unsupported platform: ${uname_out}/${arch}"
        exit 1
    fi

    case "$arch" in
        x86_64|amd64)
            archive="frp_${FRP_VERSION}_linux_amd64.tar.gz"
            ;;
        aarch64|arm64)
            archive="frp_${FRP_VERSION}_linux_arm64.tar.gz"
            ;;
        *)
            echo "❌ Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac

    echo "Downloading FRP binaries (${archive})"
    download_url "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${archive}" /tmp/frp.tar.gz
    tar -xzf /tmp/frp.tar.gz -C "$INSTALL_DIR" --strip-components=1
}

mkdir -p "$INSTALL_DIR"
if [[ ! -f "$INSTALL_DIR/frps" ]]; then
    get_frps
fi

echo
echo "🔧 Server configuration"

mkdir -p "$ACME_WEBROOT"

cat > "$INSTALL_DIR/frps.toml" <<FRPS_EOF
bindPort = ${SERVER_PORT}
subdomainHost = "${SERVER_ADDRESS}"

vhostHTTPPort = 7080

auth.method = "token"
auth.token = "${AUTH_TOKEN}"
FRPS_EOF

download_asset "templates/frps.service.tpl" "$ASSET_TMP_DIR/frps.service.tpl"
render_template "$ASSET_TMP_DIR/frps.service.tpl" /etc/systemd/system/frps.service \
    INSTALL_DIR "$INSTALL_DIR"

cat > "$INSTALL_DIR/register.env" <<REGISTER_ENV_EOF
BASE_DOMAIN=${SERVER_ADDRESS}
AUTH_TOKEN=${AUTH_TOKEN}
CERT_EMAIL=${CERT_EMAIL}
ACME_WEBROOT=${ACME_WEBROOT}
REGISTER_PORT=${REGISTER_PORT}
PROXY_UPSTREAM=http://localhost:7080
REGISTER_ENV_EOF
chmod 600 "$INSTALL_DIR/register.env"

download_asset "installer_assets/proxc_register.py" "$ASSET_TMP_DIR/proxc_register.py"
install -m 700 "$ASSET_TMP_DIR/proxc_register.py" "$INSTALL_DIR/proxc_register.py"

download_asset "templates/proxc-register.service.tpl" "$ASSET_TMP_DIR/proxc-register.service.tpl"
render_template "$ASSET_TMP_DIR/proxc-register.service.tpl" /etc/systemd/system/proxc-register.service \
    INSTALL_DIR "$INSTALL_DIR"

download_asset "templates/nginx-bootstrap.conf.tpl" "$ASSET_TMP_DIR/nginx-bootstrap.conf.tpl"
render_template "$ASSET_TMP_DIR/nginx-bootstrap.conf.tpl" /etc/nginx/sites-available/proxc \
    SERVER_ADDRESS "$SERVER_ADDRESS" \
    ACME_WEBROOT "$ACME_WEBROOT" \
    REGISTER_PORT "$REGISTER_PORT"

ln -sf /etc/nginx/sites-available/proxc /etc/nginx/sites-enabled/proxc
systemctl daemon-reload
systemctl enable --now frps.service
systemctl enable --now proxc-register.service
systemctl enable --now nginx

nginx -t
systemctl reload nginx

echo "Obtaining HTTPS certificate for ${SERVER_ADDRESS} via HTTP-01..."
certbot certonly \
    --webroot \
    -w "${ACME_WEBROOT}" \
    -d "${SERVER_ADDRESS}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring \
    -m "${CERT_EMAIL}"

download_asset "templates/nginx-final.conf.tpl" "$ASSET_TMP_DIR/nginx-final.conf.tpl"
render_template "$ASSET_TMP_DIR/nginx-final.conf.tpl" /etc/nginx/sites-available/proxc \
    SERVER_ADDRESS "$SERVER_ADDRESS" \
    ACME_WEBROOT "$ACME_WEBROOT" \
    REGISTER_PORT "$REGISTER_PORT"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
download_asset "installer_assets/proxc-nginx-reload.sh" "$ASSET_TMP_DIR/proxc-nginx-reload.sh"
install -m 755 "$ASSET_TMP_DIR/proxc-nginx-reload.sh" /etc/letsencrypt/renewal-hooks/deploy/proxc-nginx-reload.sh

nginx -t
systemctl reload nginx

echo
echo "✅ Server setup complete. FRP and registration API are running."
