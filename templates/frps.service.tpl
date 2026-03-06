[Unit]
Description=FRP Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=__INSTALL_DIR__/frps -c __INSTALL_DIR__/frps.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
