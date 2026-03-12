# PROXC - FRP-based Secure Tunnel with On-Demand HTTPS

## Overview

**PROXC** is a lightweight tunneling solution built on top of **FRP (Fast Reverse Proxy)** that exposes local services with **subdomain routing and HTTPS**.

This project provides:

- A server installer under `server/` for `frps`, Nginx, and Certbot
- A local registration API that issues certificates on demand per subdomain
- An npm client package with a simple `proxc <port> <subdomain>` command

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

## Repo Layout

- `server/` contains the server installer, uninstall script, templates, and registration assets
- `client/` contains the npm package for the client CLI

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

- Node.js 18+
- npm
- Linux or macOS
- Local app running on `localhost:<port>`

## Installation

### Server

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/server/install.sh | sudo bash
```

`server/install.sh` downloads helper assets from the `server/` directory in this repo during install.

Prompts:

- Server address (base domain, example: `yourdomain.com`)
- Server port (default `7000`)
- Auth token
- Certbot email

Server setup installs and configures:

- `/opt/frp/frps`
- `frps.service`
- `proxc-register.service`
- Nginx site config and ACME webroot
- Certbot renew hook that reloads Nginx

### Client

```bash
npm install -g @midlajc/proxc
```

Then configure the client:

```bash
proxc config
```

Client setup installs:

- The global `proxc` CLI
- `~/.proxc/config.json`
- `~/.proxc/frpc`

`proxc config` downloads `frpc` for the current platform and stores client config locally.

Optional installer overrides:

- `PROXC_ASSET_BASE_URL` to download server assets from a custom raw URL root. This should normally point to the repo `server/` directory.
- `PROXC_LOCAL_ASSET_DIR` to use local files instead of downloading during server install. This can point to either the repo root or `server/`.

## Usage

Start a tunnel:

```bash
proxc config
proxc <local_port> <subdomain>
```

Example:

```bash
proxc config
proxc 3000 app
```

This flow now does:

1. Calls registration API: `POST /_proxc/register`
2. Issues/ensures cert for `app.<base-domain>`
3. Starts FRP tunnel

Output URL:

```text
https://app.yourdomain.com
```

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

If installed with npm, ensure your npm global bin directory is in `PATH`.

## Uninstall

Server:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/server/uninstall.sh | sudo bash
```

Client:

```bash
npm uninstall -g @midlajc/proxc
rm -rf ~/.proxc ~/.cache/proxc
```
