[Unit]
Description=PROXC Subdomain Registration Service
After=network.target frps.service

[Service]
Type=simple
User=root
EnvironmentFile=__INSTALL_DIR__/register.env
ExecStart=/usr/bin/python3 __INSTALL_DIR__/proxc_register.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
