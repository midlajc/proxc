# PROXC - FRP-based Secure Tunnel with On-Demand HTTPS

## Overview

**PROXC** is a lightweight tunneling solution built on top of **FRP (Fast Reverse Proxy)** that exposes local services with **subdomain routing and HTTPS**.

This project provides a single installer that sets up:

- An FRP server (`frps`) with Nginx and Certbot
- A local registration API that issues certificates on demand per subdomain
- An admin dashboard for live FRP status and on-demand HTTP request inspection
- An FRP client with a simple `proxc <port> <subdomain>` command

## How HTTPS Works (HTTP-01)

- Base domain certificate is issued for `yourdomain.com` during server install.
- Each new subdomain (for example `app.yourdomain.com`) is issued automatically when a client starts `proxc`.
- Certificate validation uses **HTTP-01** (`/.well-known/acme-challenge/...`) via Nginx webroot.
- No Cloudflare token or DNS API plugin is required.

## Architecture

```
Local App (localhost:3000)
        |
        v
      frpc
        |
        v
     frps (Server)
        |
        v
      Nginx + Certbot + Register API
        |
        v
https://app.yourdomain.com
```

- FRP handles tunneling
- Nginx handles HTTP/HTTPS
- Register API provisions per-subdomain certificates before tunnel start

## Requirements

### Server

- Ubuntu 20.04+
- Public IP / VM
- Domain configured so both records point to server IP:
  - `yourdomain.com`
  - `*.yourdomain.com`
- Open ports:
  - `7000` (or your chosen FRP bind port)
  - `80`
  - `443`

### Client

- Linux or macOS
- Local app running on `localhost:<port>`

## Installation

### Server

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | sudo bash -s -- -server
```

`install.sh` downloads helper assets (templates and scripts) from this repo during install.

Prompts:

- Server address (base domain, example: `yourdomain.com`)
- Server port (default `7000`)
- Auth token
- Certbot email
- Admin dashboard token
- Request retention days (default `7`)
- Request body capture max KB (default `256`)
- Default capture duration minutes (default `15`)
- FRPS dashboard local credentials

Server setup installs and configures:

- `/opt/frp/frps`
- `frps.service`
- `proxc-register.service`
- Nginx site config and ACME webroot
- Admin request capture DB (`/opt/frp/proxc_admin.db`)
- Certbot renew hook that reloads Nginx

### Client

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | bash -s -- -client
```

`install.sh` downloads helper assets (templates and scripts) from this repo during install.

Client setup installs:

- `~/.proxc/frpc`
- `~/.proxc/.env`
- `~/.local/bin/proxc`

Ensure `~/.local/bin` is in your `PATH`.

Optional installer overrides:

- `PROXC_ASSET_BASE_URL` to download assets/templates from a custom raw URL root.
- `PROXC_LOCAL_ASSET_DIR` to use local files (repo root containing `installer_assets/` and `templates/`) instead of downloading.

## Usage

Start a tunnel:

```bash
proxc <local_port> <subdomain>
```

Example:

```bash
proxc 3000 app
```

This flow now does:

1. Calls registration API: `POST /_proxc/register`
2. Issues/ensures cert for `app.<base-domain>`
3. Starts FRP tunnel

Output URL:

```text
https://<subdomain>.yourdomain.com
```

## Admin Dashboard

- URL: `https://<base-domain>/_proxc/admin`
- Login: use the admin token configured during server install.
- Features:
  - Live FRPS proxy status (online/total and per-proxy stats)
  - Manual capture start/stop per subdomain
  - Request inspection for captured windows (route, params, headers, body)

Request capture is disabled by default and only stored during active capture windows.

## Validation Rules for `<subdomain>`

- Single DNS label only
- Lowercase letters, numbers, hyphens
- No dots
- No leading/trailing hyphen

## Troubleshooting

### Certificate issuance fails

- Confirm DNS for both `yourdomain.com` and `*.yourdomain.com` points to server IP.
- Confirm port `80` is publicly reachable.
- Check logs:

```bash
journalctl -u proxc-register.service -f
```

### Tunnel starts but endpoint unavailable

- Confirm FRP service:

```bash
systemctl status frps
```

- Confirm Nginx config:

```bash
nginx -t
```

### Command not found (`proxc`)

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
