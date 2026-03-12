# @midlajc/proxc

CLI for exposing a local HTTP service through a PROXC server with automatic HTTPS provisioning.

Codebase: https://github.com/midlajc/proxc

## Requirements

- Node.js 18+
- npm
- Linux or macOS
- `tar` available on the system
- Access to a configured PROXC server

## Install

```bash
npm install -g @midlajc/proxc
```

## Initialize the Client

Run the interactive setup:

```bash
proxc config
```

You can also configure it non-interactively:

```bash
proxc config \
  --server-address yourdomain.com \
  --server-port 7000 \
  --auth-token your-token \
  --register-endpoint https://yourdomain.com/_proxc/register
```

This stores client configuration in `~/.proxc/config.json` and downloads the matching `frpc` binary into `~/.proxc/frpc`.

## Usage

Start a tunnel:

```bash
proxc <local_port> <subdomain>
```

Example:

```bash
proxc 3000 app
```

If the server is configured for `yourdomain.com`, the tunnel will be available at:

```text
https://app.yourdomain.com
```

Before starting the tunnel, the CLI calls the server registration endpoint to ensure HTTPS is provisioned for the requested subdomain.

## Commands

### `proxc config`

Initializes or updates the local client config.

Supported flags:

- `--server-address <domain>`
- `--server-port <port>`
- `--auth-token <token>`
- `--register-endpoint <url>`

### `proxc config show`

Prints the active client configuration as JSON.

### `proxc <local_port> <subdomain>`

Starts a tunnel from `127.0.0.1:<local_port>` to `<subdomain>.<server-address>`.

Subdomain rules:

- lowercase letters, numbers, and hyphens only
- no dots
- no leading or trailing hyphen

## Help

```bash
proxc --help
```

`proxc init` is still accepted as a backward-compatible alias for `proxc config`.

## Troubleshooting

If `proxc config` fails while downloading FRP:

- confirm outbound access to GitHub Releases
- confirm `tar` is installed
- rerun `proxc config`

If tunnel registration fails:

- confirm the `register-endpoint` is reachable
- confirm the auth token matches the server configuration
- confirm the requested subdomain is valid

If the CLI says config is missing:

```bash
proxc config
```

## Uninstall

```bash
npm uninstall -g @midlajc/proxc
rm -rf ~/.proxc ~/.cache/proxc
```
## Server Setup

Server configuration and install assets are available in the GitHub repo:

- Repo overview: https://github.com/midlajc/proxc#readme
- Server installer: https://github.com/midlajc/proxc/blob/master/server/install.sh
- Server files: https://github.com/midlajc/proxc/tree/master/server