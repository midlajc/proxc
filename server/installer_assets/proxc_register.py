#!/usr/bin/env python3
import fcntl
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

BASE_DOMAIN = os.environ["BASE_DOMAIN"]
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "")
CERT_EMAIL = os.environ["CERT_EMAIL"]
ACME_WEBROOT = os.environ.get("ACME_WEBROOT", "/var/www/proxc-acme")
REGISTER_PORT = int(os.environ.get("REGISTER_PORT", "7090"))
PROXY_UPSTREAM = os.environ.get("PROXY_UPSTREAM", "http://localhost:7080")

NGINX_AVAILABLE_DIR = "/etc/nginx/sites-available"
NGINX_ENABLED_DIR = "/etc/nginx/sites-enabled"
LOCK_DIR = "/var/lock"

SUBDOMAIN_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def run(cmd):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def cert_exists(hostname):
    base = f"/etc/letsencrypt/live/{hostname}"
    return os.path.isfile(f"{base}/fullchain.pem") and os.path.isfile(f"{base}/privkey.pem")


def write_nginx_host_config(hostname):
    conf_name = f"proxc-{hostname}.conf"
    conf_path = os.path.join(NGINX_AVAILABLE_DIR, conf_name)
    enabled_path = os.path.join(NGINX_ENABLED_DIR, conf_name)
    content = f"""server {{
    listen 443 ssl;
    server_name {hostname};

    ssl_certificate /etc/letsencrypt/live/{hostname}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{hostname}/privkey.pem;

    location / {{
        proxy_pass {PROXY_UPSTREAM};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}
}}
"""
    with open(conf_path, "w", encoding="utf-8") as fh:
        fh.write(content)

    if os.path.islink(enabled_path) or os.path.isfile(enabled_path):
        os.remove(enabled_path)
    os.symlink(conf_path, enabled_path)


def provision_hostname(subdomain):
    hostname = f"{subdomain}.{BASE_DOMAIN}"
    os.makedirs(LOCK_DIR, exist_ok=True)
    lock_path = os.path.join(LOCK_DIR, f"proxc-register-{subdomain}.lock")

    with open(lock_path, "w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)

        if not cert_exists(hostname):
            run(
                [
                    "certbot",
                    "certonly",
                    "--webroot",
                    "-w",
                    ACME_WEBROOT,
                    "-d",
                    hostname,
                    "--agree-tos",
                    "--non-interactive",
                    "--keep-until-expiring",
                    "-m",
                    CERT_EMAIL,
                ]
            )

        write_nginx_host_config(hostname)
        run(["nginx", "-t"])
        run(["nginx", "-s", "reload"])

    return hostname


def parse_payload(content_type, raw_body):
    body_text = raw_body.decode("utf-8", errors="replace")
    if "application/json" in (content_type or ""):
        data = json.loads(body_text or "{}")
        return data.get("subdomain", ""), data.get("authToken", "")

    form = parse_qs(body_text)
    subdomain = form.get("subdomain", [""])[0]
    auth_token = form.get("authToken", [""])[0]
    return subdomain, auth_token


class RegisterHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        if self.path != "/_proxc/register":
            self._send_json(404, {"error": "not_found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "invalid_content_length"})
            return

        raw_body = self.rfile.read(length)
        try:
            subdomain, auth_token = parse_payload(self.headers.get("Content-Type", ""), raw_body)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid_json"})
            return

        subdomain = subdomain.strip().lower()

        if AUTH_TOKEN and auth_token != AUTH_TOKEN:
            self._send_json(401, {"error": "unauthorized"})
            return

        if not SUBDOMAIN_RE.fullmatch(subdomain):
            self._send_json(400, {"error": "invalid_subdomain"})
            return

        try:
            hostname = provision_hostname(subdomain)
        except subprocess.CalledProcessError as exc:
            self._send_json(
                500,
                {
                    "error": "provision_failed",
                    "command": " ".join(exc.cmd),
                    "details": (exc.stderr or "").strip()[-2000:],
                },
            )
            return
        except Exception as exc:  # pylint: disable=broad-except
            self._send_json(500, {"error": "internal_error", "details": str(exc)})
            return

        self._send_json(200, {"status": "ready", "hostname": hostname})

    def log_message(self, _format, *_args):  # ty:ignore[invalid-method-override]
        return


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", REGISTER_PORT), RegisterHandler)
    server.serve_forever()
