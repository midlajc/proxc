#!/usr/bin/env bash
set -e

FRP_VERSION="0.52.3"

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
    mkdir -p $BIN_DIR
    INSTALL_TYPE="client"
fi

# prompt user for server address and ports, allow env override for non-interactive
if [ -z "$SERVER_ADDRESS" ]; then
    read -p "Enter server address: " SERVER_ADDRESS </dev/tty
fi
if [ -z "$SERVER_PORT" ]; then
    read -p "Enter server port[7000]: " SERVER_PORT </dev/tty
fi
SERVER_PORT=${SERVER_PORT:-7000}
# if setting up server, mention to expose ports SERVER_PORT, 80 and 443
if [ "$INSTALL_TYPE" == "server" ]; then
    echo "Make sure to expose ports ${SERVER_PORT}, 80 and 443 in your firewall or cloud provider settings."
fi
#ask for auth token leave blank for none
if [ -z "$AUTH_TOKEN" ]; then
    read -p "Enter auth token (leave blank for none): " AUTH_TOKEN </dev/tty
fi
#ask for CF_TOKEN if server install
if [ "$INSTALL_TYPE" == "server" ]; then
    if [ -z "$CF_TOKEN" ]; then
        read -p "Enter Cloudflare API Token (DNS Edit): " CF_TOKEN </dev/tty
    fi
    if [ -z "$CERT_EMAIL" ]; then
        read -p "Enter Certbot email: " CERT_EMAIL </dev/tty
    fi
fi

#install nginx and certbot for server
if [ "$INSTALL_TYPE" == "server" ]; then
    echo "Installing nginx and certbot..."
    sudo apt update
    sudo apt install -y nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare
fi

function get_frpc()
{
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)     machine=Linux;;
        Darwin*)    machine=Mac;;
        CYGWIN*)    machine=Cygwin;;
        MINGW*)     machine=MinGw;;
        *)          machine="UNKNOWN:${unameOut}"
    esac

    echo "Downloading frp client for ${machine}"

    if [ ${machine} == "Linux" ]; then
        wget https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz -O /tmp/frp.tar.gz
    elif [ ${machine} == "Mac" ]; then
            wget https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_darwin_arm64.tar.gz -O /tmp/frp.tar.gz
        fi

    tar -xvzf /tmp/frp.tar.gz -C $INSTALL_DIR --strip-components=1
}

# ---------- COMMON ----------
mkdir -p $INSTALL_DIR
if [ ! -f  $INSTALL_DIR/frpc ]; then
  get_frpc
fi

if [ "$INSTALL_TYPE" == "server" ]; then
echo
echo "🔧 Server configuration"

# FRPS CONFIG
cat > $INSTALL_DIR/frps.toml <<EOF
bindPort = ${SERVER_PORT}
subdomainHost = "${SERVER_ADDRESS}"

vhostHTTPPort = 7080

auth.method = "token"
auth.token = "${AUTH_TOKEN}"
EOF

# SYSTEMD SERVICE
cat > /etc/systemd/system/frps.service <<EOF
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
EOF

# ENABLE AND START SERVICE
systemctl daemon-reload
systemctl enable frps.service
systemctl start frps.service

# Obtain SSL certificates using Certbot
echo "Obtaining SSL certificates for ${SERVER_ADDRESS}..."
mkdir -p /root/.secrets/certbot
cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_TOKEN}
EOF
chmod 600 /root/.secrets/certbot/cloudflare.ini
certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    -d "*.${SERVER_ADDRESS}" \
    -d "${SERVER_ADDRESS}" \
    --agree-tos \
    --non-interactive \
    -m "${CERT_EMAIL}"

# Configure Nginx
echo "Configuring Nginx..."
cat > /etc/nginx/sites-available/proxc <<EOF
server {
    listen 80;
    server_name ${SERVER_ADDRESS} *.${SERVER_ADDRESS};

    location / {
        proxy_pass http://localhost:7080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    server_name ${SERVER_ADDRESS} *.${SERVER_ADDRESS};

    ssl_certificate /etc/letsencrypt/live/${SERVER_ADDRESS}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SERVER_ADDRESS}/privkey.pem;

    location / {
        proxy_pass http://localhost:7080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/proxc /etc/nginx/sites-enabled/proxc
nginx -t
nginx -s reload

echo
echo "✅ Server setup complete. FRP server is running."
exit 0
fi

if [ "$INSTALL_TYPE" == "client" ]; then
echo
echo "🔧 Client configuration"

cat > $INSTALL_DIR/.env <<EOF
SERVER_ADDRESS=${SERVER_ADDRESS}
SERVER_PORT=${SERVER_PORT}
AUTH_TOKEN=${AUTH_TOKEN}
EOF
chmod 600 $INSTALL_DIR/.env

cat > $BIN_DIR/proxc <<'EOF'
#!/usr/bin/env bash
set -e

ENV_FILE="$HOME/.proxc/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Missing $HOME/.proxc/.env"
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

echo "🚀 Tunnel started → https://${SUBDOMAIN}.${SERVER_ADDRESS}"
exec $HOME/.proxc/frpc -c "$CFG"
EOF

chmod +x $BIN_DIR/proxc

echo
echo "✅ Client setup complete. Use the 'proxc' command to start tunnels."
fi