#!/bin/bash
set -e

FRP_VERSION="0.52.3"

# prompt user for client or server installation
read -p "Install FRP as (c)lient or (s)erver? " MODE

if [ "$MODE" == "s" ]; then
    INSTALL_DIR="/opt/frp"
else
    INSTALL_DIR="$HOME/.proxc"
    BIN_DIR="$HOME/.local/bin"
fi

if [ "$MODE" == "s" ]; then
    echo "Uninstalling FRP server..."
    sudo systemctl stop frps
    sudo systemctl disable frps
    sudo rm /etc/systemd/system/frps.service
    sudo systemctl daemon-reload
    sudo rm -rf $INSTALL_DIR
    sudo rm -f /etc/nginx/sites-available/proxc
    sudo rm -f /etc/nginx/sites-enabled/proxc
    sudo nginx -t
    sudo systemctl reload nginx
    echo "FRP server uninstalled."
else
    echo "Uninstalling FRP client..."
    rm -f $BIN_DIR/proxc
    rm -rf $INSTALL_DIR
    echo "FRP client uninstalled."
fi