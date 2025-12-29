# PROXC – FRP-based Secure Tunnel with Subdomain & HTTPS Support

## Overview

**PROXC** is a lightweight tunneling solution built on top of **FRP (Fast Reverse Proxy)** that allows you to securely expose local services to the internet using **subdomains and HTTPS**, without manual configuration every time.

This project provides a **single interactive Bash installer** that can set up:

* ✅ An **FRP server** with:

  * Subdomain-based routing
  * Automatic HTTPS using **Certbot + Cloudflare DNS**
  * Nginx reverse proxy
  * Systemd service for reliability

* ✅ An **FRP client** with:

  * Simple `proxc <port> <subdomain>` CLI
  * Token-based authentication
  * Zero manual config files per tunnel


## What This Script Is For

This script is designed to:

* Expose **local development servers** (web apps, APIs, dashboards)
* Avoid port forwarding or router configuration
* Provide **HTTPS + wildcard subdomains**

* Offer **repeatable, automated server setup**



## Technologies Used

This script integrates multiple tools into one automated flow:

| Component              | Purpose                       |
| ---------------------- | ----------------------------- |
| **FRP (frps / frpc)**  | Reverse proxy tunneling       |
| **Nginx**              | HTTP/HTTPS reverse proxy      |
| **Certbot**            | SSL certificates              |



## Architecture Overview

```
Local App (localhost:3000)
        │
        ▼
      frpc
        │
        ▼
     frps (Server)
        │
        ▼
      Nginx
        │
        ▼
https://subdomain.yourdomain.com
```

* FRP handles tunneling
* Nginx handles HTTPS & routing


## Requirements

### Server Requirements

* Ubuntu 20.04+ (recommended)
* Public IP or cloud VM
* Domain name (e.g. `example.com`)
* Cloudflare DNS (domain must be managed by Cloudflare)
* Ports open:

  * `7000` (FRP, configurable)
  * `80`
  * `443`

### Client Requirements

* Linux or macOS
* No root access required
* Any local service running on `localhost`


&nbsp;  

# Installation

## Server Installation (FRP Server)

Run the installer and follow the prompts:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | sudo bash -s -- -server
```

> **Note:** Server installation requires `sudo` access.

### You Will Be Asked For:

| Prompt               | Description                        |
| -------------------- | ---------------------------------- |
| Server address       | Your domain (e.g. `example.com`)   |
| Server port          | FRP bind port (default `7000`)     |
| Auth token           | Shared secret for clients          |
| Cloudflare API Token | Token with **DNS Edit** permission |
| Certbot email        | Email for SSL certificates         |

### What Happens Automatically

* FRP server (`frps`) installed in `/opt/frp`
* Systemd service created and enabled
* Nginx installed and configured
* Wildcard SSL certificates issued:

  * `*.example.com`
  * `example.com`
* HTTP → HTTPS ready
* Subdomain routing enabled

### Server Status Check

```bash
systemctl status frps
```

---

## Client Installation (FRP Client)

On your **local machine**, run:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/install.sh | bash -s -- -client
```

### Client Setup Details

* FRP client installed to: `~/.proxc`
* Config stored securely in: `~/.proxc/.env`
* CLI installed to: `~/.local/bin/proxc`

Ensure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

---

## Using PROXC (Client)

### Start a Tunnel

```bash
proxc <local_port> <subdomain>
```

### Example

```bash
proxc 3000 app
```

This exposes:

```
https://app.example.com → http://localhost:3000
```

### Another Example

```bash
proxc 8080 api
```

```
https://api.example.com → http://localhost:8080
```

Each tunnel:

* Uses HTTPS automatically
* Is isolated per subdomain
* Requires no Nginx or SSL config on client side


## Authentication & Security

* Uses **token-based authentication**
* Token must match between server and client
* SSL certificates are managed automatically
* Cloudflare API token is stored with `600` permissions



## File & Directory Layout

### Server

```
/opt/frp/
 ├─ frps
 ├─ frps.toml
```

```
/etc/systemd/system/frps.service
/etc/nginx/sites-available/proxc
/etc/letsencrypt/live/example.com/
```

### Client

```
~/.proxc/
 ├─ frpc
 ├─ .env
```

```
~/.cache/proxc/
 ├─ subdomain.toml
```



## Troubleshooting

### FRP Server Not Reachable

* Ensure port `7000` (or custom) is open
* Check firewall rules
* Verify DNS points to server IP

### SSL Issues

* Confirm Cloudflare token has **DNS Edit**
* Domain must be proxied **off** (DNS only) for validation

### Command Not Found

```bash
which proxc
```

Ensure `~/.local/bin` is in PATH.


## Uninstall Notes

* Remove FRP service:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/uninstall.sh | sudo bash -s -- -server
```

* Remove client:

```bash
curl -o- https://raw.githubusercontent.com/midlajc/proxc/refs/heads/master/uninstall.sh | bash -s -- -client
```


## Summary

**PROXC** gives you:

* Self-hosted tunneling
* HTTPS by default
* Subdomain routing
* One-command usage
