#!/usr/bin/env bash
set -e

FRP_VERSION="0.52.3"

# check for -c (client) or -s (server) flag, else prompt user
if [[ "$1" == "-client" ]]; then
    MODE="c"
elif [[ "$1" == "-server" ]]; then
    MODE="s"
else
    read -p "Install FRP as (c)lient or (s)erver? " MODE
fi

if [ "$MODE" == "s" ]; then
    INSTALL_DIR="/opt/frp"
    MODE="server"
else
    INSTALL_DIR="$HOME/.proxc"
    BIN_DIR="$HOME/.local/bin"
    MODE="client"
fi

if [ "$MODE" == "server" ]; then
    echo "Uninstalling FRP server..."
    sudo systemctl stop frps
    sudo systemctl disable frps
    sudo rm /etc/systemd/system/frps.service
    sudo systemctl daemon-reload
    sudo rm -rf $INSTALL_DIR

    if systemctl list-unit-files | grep -q '^openresty\.service'; then
        sudo systemctl stop openresty || true
        sudo systemctl disable openresty || true
        sudo rm -f /etc/openresty/nginx.conf
        sudo rm -f /etc/openresty/init_by_lua/proxc_auto_ssl.lua
        sudo rm -rf /var/lib/proxc/auto-ssl
        sudo rm -f /etc/ssl/proxc/fallback.crt
        sudo rm -f /etc/ssl/proxc/fallback.key
    fi

    if systemctl list-unit-files | grep -q '^nginx\.service'; then
        sudo rm -f /etc/nginx/sites-available/proxc
        sudo rm -f /etc/nginx/sites-enabled/proxc
        sudo nginx -t || true
        sudo systemctl reload nginx || true
    fi

    sudo rm -f /root/.secrets/certbot/cloudflare.ini
    echo "FRP server uninstalled."
else
    echo "Uninstalling FRP client..."
    rm -f $BIN_DIR/proxc
    rm -rf $INSTALL_DIR
    echo "FRP client uninstalled."
fi
