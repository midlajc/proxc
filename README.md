# PROXC - FRP-based Secure Tunnel with Subdomain HTTPS

## Overview

**PROXC** is a lightweight tunneling solution built on top of **FRP (Fast Reverse Proxy)**.
It exposes local services to the internet with subdomains and HTTPS.

The installer supports:

- FRP server (`frps`) with systemd
- FRP client (`frpc`) + `proxc <port> <subdomain>` CLI
- HTTPS termination for subdomains
  - `SSL_MODE=ondemand` (default): OpenResty + `lua-resty-auto-ssl` on-demand certificates
  - `SSL_MODE=cloudflare`: Certbot wildcard certificates via Cloudflare DNS

## Architecture

```text
Local App (localhost:3000)
        |
        v
      frpc
        |
        v
     frps (Server, vhostHTTPPort=7080)
        |
        v
OpenResty/Nginx TLS termination
        |
        v
https://subdomain.yourdomain.com
```

## Requirements

### Server

- Ubuntu 20.04+
- Public IP / cloud VM
- Domain name (e.g. `example.com`)
- DNS records:
  - `A example.com -> <server-ip>`
  - `A *.example.com -> <server-ip>`
- Open ports:
  - `7000` (or custom FRP bind port)
  - `80`
  - `443`

### Client

- Linux or macOS
- Any local service listening on `localhost`

## Installation

### Server Install

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | sudo bash -s -- -server
```

You will be prompted for:

| Prompt | Description |
| --- | --- |
| Server address | Root domain, e.g. `example.com` |
| Server port | FRP bind port (default `7000`) |
| Auth token | Shared token between server/client |
| SSL mode | `ondemand` (default) or `cloudflare` |
| ACME/Certbot email | Registration email for certificate issuer |
| ACME CA | `production` or `staging` (ondemand mode) |
| Cloudflare API token | Only when `SSL_MODE=cloudflare` |

### Non-interactive Server Install (On-Demand SSL)

```bash
SERVER_ADDRESS=example.com \
SERVER_PORT=7000 \
AUTH_TOKEN=change-me \
SSL_MODE=ondemand \
SSL_ONDEMAND_DOMAIN=example.com \
ACME_CA=production \
CERT_EMAIL=admin@example.com \
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | sudo bash -s -- -server
```

### Client Install

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | bash -s -- -client
```

## Usage

Start a tunnel:

```bash
proxc <local_port> <subdomain>
```

Example:

```bash
proxc 3000 app
```

Output URL:

```text
https://app.example.com
```

## SSL Modes

### 1) `SSL_MODE=ondemand` (Default)

- Uses OpenResty + Lua ACME automation
- Issues cert on first HTTPS request per hostname
- Keeps private keys on server
- Auto-renews managed certs
- Restricts issuance to `SSL_ONDEMAND_DOMAIN` and its subdomains
- If issuer rate limits are hit, new host issuance fails temporarily while existing hosts continue to work

### 2) `SSL_MODE=cloudflare`

- Uses Certbot DNS-01 with Cloudflare token
- Issues wildcard cert (`*.example.com` + `example.com`)

## Health Checks

FRP service:

```bash
systemctl status frps
```

OpenResty logs (ondemand mode):

```bash
journalctl -u openresty -f
```

TLS check for a subdomain:

```bash
openssl s_client -connect example.com:443 -servername app.example.com
```

## Files and Paths

### Server

```text
/opt/frp/
  frps
  frps.toml

/etc/systemd/system/frps.service
```

On-demand SSL mode:

```text
/etc/openresty/nginx.conf
/etc/openresty/init_by_lua/proxc_auto_ssl.lua
/var/lib/proxc/auto-ssl/
/etc/ssl/proxc/fallback.crt
/etc/ssl/proxc/fallback.key
```

Cloudflare mode:

```text
/etc/nginx/sites-available/proxc
/etc/nginx/sites-enabled/proxc
/root/.secrets/certbot/cloudflare.ini
/etc/letsencrypt/live/<domain>/
```

### Client

```text
~/.proxc/
  frpc
  .env

~/.cache/proxc/
  <subdomain>.toml

~/.local/bin/proxc
```

## Security Notes

- FRP access is token-protected (`AUTH_TOKEN`)
- On-demand mode denies certificate issuance for non-matching hostnames
- TLS private keys stay on the server in on-demand mode
- Cloudflare token file (cloudflare mode) is stored with `600` permissions

## Troubleshooting

### New Subdomain TLS Fails in On-Demand Mode

- Ensure DNS wildcard record points to the server
- Ensure ports `80` and `443` are reachable from internet
- Check issuer rate limits for many new hostnames
- Inspect logs:

```bash
journalctl -u openresty -f
```

### FRP Server Unreachable

- Check `frps` status:

```bash
systemctl status frps
```

- Verify firewall and cloud security group rules
- Verify DNS points to server IP

### `proxc` Not Found

```bash
which proxc
```

Ensure `~/.local/bin` is in `PATH`.

## Uninstall

Server:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/uninstall.sh | sudo bash -s -- -server
```

Client:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/uninstall.sh | bash -s -- -client
```
