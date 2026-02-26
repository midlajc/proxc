#!/usr/bin/env bash
set -e

FRP_VERSION="0.52.3"

OPENRESTY_CONF_PATH="/etc/openresty/nginx.conf"
OPENRESTY_LUA_INIT_PATH="/etc/openresty/init_by_lua/proxc_auto_ssl.lua"
OPENRESTY_FALLBACK_CERT_DIR="/etc/ssl/proxc"
OPENRESTY_AUTO_SSL_DIR="/var/lib/proxc/auto-ssl"

# check for -c (client) or -s (server) flag, else prompt user
if [[ "$1" == "-client" ]]; then
    INSTALL_TYPE="c"
elif [[ "$1" == "-server" ]]; then
    INSTALL_TYPE="s"
else
    read -p "Install FRP as (c)lient or (s)erver? " INSTALL_TYPE </dev/tty
fi

if [ "$INSTALL_TYPE" == "s" ]; then
    INSTALL_DIR="/opt/frp"
    INSTALL_TYPE="server"
else
    INSTALL_DIR="$HOME/.proxc"
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    INSTALL_TYPE="client"
fi

# prompt user for server address and ports, allow env override for non-interactive
if [ -z "$SERVER_ADDRESS" ]; then
    read -p "Enter server address: " SERVER_ADDRESS </dev/tty
fi
if [ -z "$SERVER_PORT" ]; then
    read -p "Enter server port [7000]: " SERVER_PORT </dev/tty
fi
SERVER_PORT=${SERVER_PORT:-7000}

# if setting up server, mention to expose ports SERVER_PORT, 80 and 443
if [ "$INSTALL_TYPE" == "server" ]; then
    echo "Make sure to expose ports ${SERVER_PORT}, 80 and 443 in your firewall or cloud provider settings."
fi

# ask for auth token leave blank for none
if [ -z "$AUTH_TOKEN" ]; then
    read -p "Enter auth token (leave blank for none): " AUTH_TOKEN </dev/tty
fi

if [ "$INSTALL_TYPE" == "server" ]; then
    if [ -z "$SSL_MODE" ]; then
        read -p "Enter SSL mode ([ondemand]/cloudflare): " SSL_MODE </dev/tty
    fi
    SSL_MODE=${SSL_MODE:-ondemand}

    if [ "$SSL_MODE" != "ondemand" ] && [ "$SSL_MODE" != "cloudflare" ]; then
        echo "Invalid SSL_MODE '${SSL_MODE}'. Use 'ondemand' or 'cloudflare'."
        exit 1
    fi

    if [ -z "$CERT_EMAIL" ]; then
        read -p "Enter ACME/Certbot email: " CERT_EMAIL </dev/tty
    fi

    if [ "$SSL_MODE" == "cloudflare" ]; then
        if [ -z "$CF_TOKEN" ]; then
            read -p "Enter Cloudflare API Token (DNS Edit): " CF_TOKEN </dev/tty
        fi
    else
        SSL_ONDEMAND_DOMAIN=${SSL_ONDEMAND_DOMAIN:-$SERVER_ADDRESS}

        if [ -z "$ACME_CA" ]; then
            read -p "ACME CA ([production]/staging): " ACME_CA </dev/tty
        fi
        ACME_CA=${ACME_CA:-production}

        if [ "$ACME_CA" == "staging" ]; then
            ACME_CA_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
        elif [ "$ACME_CA" == "production" ]; then
            ACME_CA_URL="https://acme-v02.api.letsencrypt.org/directory"
        else
            echo "Invalid ACME_CA '${ACME_CA}'. Use 'production' or 'staging'."
            exit 1
        fi
    fi
fi

function install_openresty_packages()
{
    echo "Installing OpenResty and Lua dependencies..."
    sudo apt update
    sudo apt install -y curl gnupg2 ca-certificates lsb-release software-properties-common openssl luarocks

    if ! dpkg -s openresty >/dev/null 2>&1; then
        local codename
        codename="$(lsb_release -sc)"

        if [ ! -f /usr/share/keyrings/openresty.gpg ]; then
            curl -fsSL https://openresty.org/package/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openresty.gpg
        fi

        echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu ${codename} main" | sudo tee /etc/apt/sources.list.d/openresty.list >/dev/null
        sudo apt update
        sudo apt install -y openresty
    else
        sudo apt install -y openresty
    fi

    if [ -x /usr/local/openresty/bin/opm ]; then
        /usr/local/openresty/bin/opm get auto-ssl/lua-resty-auto-ssl >/dev/null 2>&1 || true
    elif command -v opm >/dev/null 2>&1; then
        opm get auto-ssl/lua-resty-auto-ssl >/dev/null 2>&1 || true
    fi

    if [ ! -f /usr/local/openresty/site/lualib/resty/auto-ssl.lua ] && [ ! -f /usr/local/share/lua/5.1/resty/auto-ssl.lua ]; then
        sudo luarocks install lua-resty-auto-ssl
    fi

    if [ ! -f /usr/local/openresty/site/lualib/resty/http.lua ] && [ ! -f /usr/local/share/lua/5.1/resty/http.lua ]; then
        sudo luarocks install lua-resty-http
    fi
}

# install dependencies for server
if [ "$INSTALL_TYPE" == "server" ]; then
    if [ "$SSL_MODE" == "cloudflare" ]; then
        echo "Installing nginx and certbot..."
        sudo apt update
        sudo apt install -y nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare
    else
        install_openresty_packages
    fi
fi

function get_frpc()
{
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)     machine=Linux;;
        Darwin*)    machine=Mac;;
        CYGWIN*)    machine=Cygwin;;
        MINGW*)     machine=MinGw;;
        *)          machine="UNKNOWN:${unameOut}";;
    esac

    echo "Downloading frp client for ${machine}"

    if [ "${machine}" == "Linux" ]; then
        wget "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz" -O /tmp/frp.tar.gz
    elif [ "${machine}" == "Mac" ]; then
        wget "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_darwin_arm64.tar.gz" -O /tmp/frp.tar.gz
    else
        echo "Unsupported platform: ${machine}"
        exit 1
    fi

    tar -xvzf /tmp/frp.tar.gz -C "$INSTALL_DIR" --strip-components=1
}

function configure_cloudflare_ssl()
{
    echo "Obtaining wildcard SSL certificates for ${SERVER_ADDRESS} via Cloudflare DNS..."
    if systemctl list-unit-files | grep -q '^openresty\.service'; then
        systemctl stop openresty || true
        systemctl disable openresty || true
    fi

    mkdir -p /root/.secrets/certbot
    cat > /root/.secrets/certbot/cloudflare.ini <<CF_EOF
dns_cloudflare_api_token = ${CF_TOKEN}
CF_EOF
    chmod 600 /root/.secrets/certbot/cloudflare.ini

    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
        -d "*.${SERVER_ADDRESS}" \
        -d "${SERVER_ADDRESS}" \
        --agree-tos \
        --non-interactive \
        -m "${CERT_EMAIL}"

    echo "Configuring Nginx..."
    cat > /etc/nginx/sites-available/proxc <<'NGINX_EOF'
server {
    listen 80;
    server_name __SERVER_ADDRESS__ *.__SERVER_ADDRESS__;

    location / {
        proxy_pass http://localhost:7080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 443 ssl;
    server_name __SERVER_ADDRESS__ *.__SERVER_ADDRESS__;

    ssl_certificate /etc/letsencrypt/live/__SERVER_ADDRESS__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__SERVER_ADDRESS__/privkey.pem;

    location / {
        proxy_pass http://localhost:7080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_EOF
    sed -i "s|__SERVER_ADDRESS__|${SERVER_ADDRESS}|g" /etc/nginx/sites-available/proxc

    ln -sf /etc/nginx/sites-available/proxc /etc/nginx/sites-enabled/proxc
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
}

function configure_openresty_ondemand_ssl()
{
    echo "Configuring OpenResty on-demand SSL for ${SSL_ONDEMAND_DOMAIN}..."

    if systemctl list-unit-files | grep -q '^nginx\.service'; then
        systemctl stop nginx || true
        systemctl disable nginx || true
    fi

    mkdir -p /etc/openresty/init_by_lua
    mkdir -p /etc/openresty/conf.d
    mkdir -p "$OPENRESTY_FALLBACK_CERT_DIR"
    mkdir -p "$OPENRESTY_AUTO_SSL_DIR"
    mkdir -p /var/log/openresty

    chmod 700 "$OPENRESTY_AUTO_SSL_DIR"

    cat > "$OPENRESTY_LUA_INIT_PATH" <<'LUA_EOF'
local auto_ssl = (require "resty.auto-ssl").new()
local allowed_root = "__SSL_ONDEMAND_DOMAIN__"
local allowed_suffix = "." .. allowed_root

auto_ssl:set("storage_adapter", "file")
auto_ssl:set("dir", "__OPENRESTY_AUTO_SSL_DIR__")
auto_ssl:set("ca", "__ACME_CA_URL__")
auto_ssl:set("hook_server_port", 8999)
auto_ssl:set("renew_check_interval", 86400)
auto_ssl:set("dehydrated_env", {
  CONTACT_EMAIL = "__CERT_EMAIL__",
})

auto_ssl:set("allow_domain", function(domain)
  if not domain then
    return false
  end

  domain = string.lower(domain)

  if domain == allowed_root then
    return true
  end

  if #domain > #allowed_suffix and domain:sub(-#allowed_suffix) == allowed_suffix then
    return true
  end

  return false
end)

auto_ssl:init()

_G.auto_ssl = auto_ssl
LUA_EOF
    sed -i "s|__SSL_ONDEMAND_DOMAIN__|${SSL_ONDEMAND_DOMAIN}|g" "$OPENRESTY_LUA_INIT_PATH"
    sed -i "s|__OPENRESTY_AUTO_SSL_DIR__|${OPENRESTY_AUTO_SSL_DIR}|g" "$OPENRESTY_LUA_INIT_PATH"
    sed -i "s|__ACME_CA_URL__|${ACME_CA_URL}|g" "$OPENRESTY_LUA_INIT_PATH"
    sed -i "s|__CERT_EMAIL__|${CERT_EMAIL}|g" "$OPENRESTY_LUA_INIT_PATH"

    cat > "$OPENRESTY_CONF_PATH" <<'OPENRESTY_EOF'
worker_processes auto;
user www-data;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format proxc_main '$remote_addr - $host [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                          'rt=$request_time ua="$upstream_addr" us="$upstream_status"';

    access_log /var/log/openresty/access.log proxc_main;
    error_log /var/log/openresty/error.log warn;

    lua_package_path "/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;";
    lua_shared_dict auto_ssl 32m;
    lua_shared_dict auto_ssl_settings 64k;
    lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    lua_ssl_verify_depth 5;

    init_by_lua_file __OPENRESTY_LUA_INIT_PATH__;
    init_worker_by_lua_block {
        auto_ssl:init_worker()
    }

    server {
        listen 80 default_server;
        server_name _;

        location /.well-known/acme-challenge/ {
            content_by_lua_block {
                auto_ssl:challenge_server()
            }
        }

        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 443 ssl http2 default_server;
        server_name _;

        ssl_certificate __OPENRESTY_FALLBACK_CERT_DIR__/fallback.crt;
        ssl_certificate_key __OPENRESTY_FALLBACK_CERT_DIR__/fallback.key;

        ssl_certificate_by_lua_block {
            auto_ssl:ssl_certificate()
        }

        location / {
            access_by_lua_block {
                local host = ngx.var.host
                if not host then
                    return ngx.exit(421)
                end

                host = string.lower(host)
                local allowed_root = "__SSL_ONDEMAND_DOMAIN__"
                local allowed_suffix = "." .. allowed_root

                if host == allowed_root then
                    return
                end

                if #host > #allowed_suffix and host:sub(-#allowed_suffix) == allowed_suffix then
                    return
                end

                return ngx.exit(421)
            }

            proxy_pass http://127.0.0.1:7080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

    server {
        listen 127.0.0.1:8999;
        server_name localhost;

        location / {
            content_by_lua_block {
                auto_ssl:hook_server()
            }
        }
    }
}
OPENRESTY_EOF
    sed -i "s|__OPENRESTY_LUA_INIT_PATH__|${OPENRESTY_LUA_INIT_PATH}|g" "$OPENRESTY_CONF_PATH"
    sed -i "s|__OPENRESTY_FALLBACK_CERT_DIR__|${OPENRESTY_FALLBACK_CERT_DIR}|g" "$OPENRESTY_CONF_PATH"
    sed -i "s|__SSL_ONDEMAND_DOMAIN__|${SSL_ONDEMAND_DOMAIN}|g" "$OPENRESTY_CONF_PATH"

    if [ ! -f "${OPENRESTY_FALLBACK_CERT_DIR}/fallback.crt" ] || [ ! -f "${OPENRESTY_FALLBACK_CERT_DIR}/fallback.key" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "${OPENRESTY_FALLBACK_CERT_DIR}/fallback.key" \
            -out "${OPENRESTY_FALLBACK_CERT_DIR}/fallback.crt" \
            -days 3650 \
            -subj "/CN=${SSL_ONDEMAND_DOMAIN}" >/dev/null 2>&1
    fi

    if [ -d /usr/local/openresty/nginx/conf ]; then
        ln -sf "$OPENRESTY_CONF_PATH" /usr/local/openresty/nginx/conf/nginx.conf
    fi

    openresty -t -c "$OPENRESTY_CONF_PATH"
    systemctl enable openresty
    systemctl restart openresty
}

# ---------- COMMON ----------
mkdir -p "$INSTALL_DIR"
if [ "$INSTALL_TYPE" == "server" ]; then
    if [ ! -f "$INSTALL_DIR/frps" ]; then
      get_frpc
    fi
else
    if [ ! -f "$INSTALL_DIR/frpc" ]; then
      get_frpc
    fi
fi

if [ "$INSTALL_TYPE" == "server" ]; then
echo
echo "Server configuration"

# FRPS CONFIG
cat > "$INSTALL_DIR/frps.toml" <<FRPS_EOF
bindPort = ${SERVER_PORT}
subdomainHost = "${SERVER_ADDRESS}"

vhostHTTPPort = 7080

auth.method = "token"
auth.token = "${AUTH_TOKEN}"
FRPS_EOF

# SYSTEMD SERVICE
cat > /etc/systemd/system/frps.service <<SERVICE_EOF
[Unit]
Description=FRP Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/frps -c ${INSTALL_DIR}/frps.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# ENABLE AND START SERVICE
systemctl daemon-reload
systemctl enable frps.service
systemctl restart frps.service

if [ "$SSL_MODE" == "cloudflare" ]; then
    configure_cloudflare_ssl
else
    configure_openresty_ondemand_ssl
fi

echo
echo "Server setup complete. FRP server is running."
if [ "$SSL_MODE" == "ondemand" ]; then
    echo "On-demand TLS is active with OpenResty for *.${SSL_ONDEMAND_DOMAIN}"
    echo "Health check: openssl s_client -connect ${SERVER_ADDRESS}:443 -servername test.${SSL_ONDEMAND_DOMAIN}"
    echo "Logs: journalctl -u openresty -f"
fi
exit 0
fi

if [ "$INSTALL_TYPE" == "client" ]; then
echo
echo "Client configuration"

cat > "$INSTALL_DIR/.env" <<CLIENT_ENV_EOF
SERVER_ADDRESS=${SERVER_ADDRESS}
SERVER_PORT=${SERVER_PORT}
AUTH_TOKEN=${AUTH_TOKEN}
CLIENT_ENV_EOF
chmod 600 "$INSTALL_DIR/.env"

cat > "$BIN_DIR/proxc" <<'CLIENT_BIN_EOF'
#!/usr/bin/env bash
set -e

ENV_FILE="$HOME/.proxc/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $HOME/.proxc/.env"
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

PORT=$1
SUBDOMAIN=$2

if [ -z "$PORT" ] || [ -z "$SUBDOMAIN" ]; then
  echo "Usage: proxc <port> <subdomain>"
  exit 1
fi

mkdir -p ~/.cache/proxc
rm -f ~/.cache/proxc/${SUBDOMAIN}.toml

CFG="$HOME/.cache/proxc/${SUBDOMAIN}.toml"
cat > "$CFG" <<CFGEOF
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
CFGEOF

echo "Tunnel started -> https://${SUBDOMAIN}.${SERVER_ADDRESS}"
exec "$HOME/.proxc/frpc" -c "$CFG"
CLIENT_BIN_EOF

chmod +x "$BIN_DIR/proxc"

echo
echo "Client setup complete. Use the 'proxc' command to start tunnels."
fi
