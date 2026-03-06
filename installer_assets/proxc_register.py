#!/usr/bin/env python3
import base64
import fcntl
import html
import json
import os
import re
import secrets
import sqlite3
import subprocess
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

BASE_DOMAIN = os.environ["BASE_DOMAIN"]
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "")
CERT_EMAIL = os.environ["CERT_EMAIL"]
ACME_WEBROOT = os.environ.get("ACME_WEBROOT", "/var/www/proxc-acme")
REGISTER_PORT = int(os.environ.get("REGISTER_PORT", "7090"))
PROXY_UPSTREAM = os.environ.get("PROXY_UPSTREAM", "http://localhost:7080")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")
REQUEST_RETENTION_DAYS = int(os.environ.get("REQUEST_RETENTION_DAYS", "7"))
REQUEST_BODY_MAX_KB = int(os.environ.get("REQUEST_BODY_MAX_KB", "256"))
CAPTURE_DEFAULT_DURATION_MINUTES = int(os.environ.get("CAPTURE_DEFAULT_DURATION_MINUTES", "15"))
ADMIN_SESSION_TTL_SECONDS = int(os.environ.get("ADMIN_SESSION_TTL_SECONDS", "43200"))
PROXC_ADMIN_DB_PATH = os.environ.get("PROXC_ADMIN_DB_PATH", "/opt/frp/proxc_admin.db")
FRPS_DASHBOARD_URL = os.environ.get("FRPS_DASHBOARD_URL", "http://127.0.0.1:7500")
FRPS_DASHBOARD_USER = os.environ.get("FRPS_DASHBOARD_USER", "")
FRPS_DASHBOARD_PASS = os.environ.get("FRPS_DASHBOARD_PASS", "")
MIRROR_SHARED_SECRET = os.environ.get("MIRROR_SHARED_SECRET", "")

NGINX_AVAILABLE_DIR = "/etc/nginx/sites-available"
NGINX_ENABLED_DIR = "/etc/nginx/sites-enabled"
LOCK_DIR = "/var/lock"

REQUEST_RETENTION_SECONDS = REQUEST_RETENTION_DAYS * 24 * 60 * 60
REQUEST_BODY_MAX_BYTES = max(1, REQUEST_BODY_MAX_KB) * 1024
SESSION_COOKIE_NAME = "proxc_admin_session"

SUBDOMAIN_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

SESSIONS = {}
SESSIONS_LOCK = threading.Lock()
CLEANUP_LOCK = threading.Lock()
LAST_CLEANUP_TS = 0


def run(cmd):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def db_connect():
    conn = sqlite3.connect(PROXC_ADMIN_DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db():
    db_dir = os.path.dirname(PROXC_ADMIN_DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    with db_connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS captured_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at INTEGER NOT NULL,
                hostname TEXT NOT NULL,
                method TEXT NOT NULL,
                path TEXT NOT NULL,
                query TEXT NOT NULL,
                remote_addr TEXT,
                scheme TEXT,
                headers_json TEXT NOT NULL,
                body_text TEXT,
                body_truncated INTEGER NOT NULL,
                body_bytes INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS capture_sessions (
                hostname TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS issued_hosts (
                hostname TEXT PRIMARY KEY,
                issued_at INTEGER NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_requests_captured_at ON captured_requests(captured_at DESC)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_requests_hostname ON captured_requests(hostname, captured_at DESC)")


def maybe_cleanup_old_data():
    global LAST_CLEANUP_TS
    now = int(time.time())
    if now - LAST_CLEANUP_TS < 300:
        return

    with CLEANUP_LOCK:
        if now - LAST_CLEANUP_TS < 300:
            return
        cutoff = now - REQUEST_RETENTION_SECONDS
        with db_connect() as conn:
            conn.execute("DELETE FROM captured_requests WHERE captured_at < ?", (cutoff,))
            conn.execute("UPDATE capture_sessions SET enabled = 0 WHERE enabled = 1 AND expires_at <= ?", (now,))
        LAST_CLEANUP_TS = now


def cert_exists(hostname):
    base = f"/etc/letsencrypt/live/{hostname}"
    return os.path.isfile(f"{base}/fullchain.pem") and os.path.isfile(f"{base}/privkey.pem")


def nginx_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def write_nginx_host_config(hostname):
    conf_name = f"proxc-{hostname}.conf"
    conf_path = os.path.join(NGINX_AVAILABLE_DIR, conf_name)
    enabled_path = os.path.join(NGINX_ENABLED_DIR, conf_name)
    mirror_secret = nginx_escape(MIRROR_SHARED_SECRET)
    content = f"""server {{
    listen 443 ssl;
    server_name {hostname};

    ssl_certificate /etc/letsencrypt/live/{hostname}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{hostname}/privkey.pem;

    location = /_proxc_mirror {{
        internal;
        proxy_pass http://127.0.0.1:{REGISTER_PORT}/_proxc/internal/mirror;
        proxy_set_header X-Proxc-Mirror-Secret \"{mirror_secret}\";
        proxy_set_header X-Proxc-Original-Host $host;
        proxy_set_header X-Proxc-Original-Uri $request_uri;
        proxy_set_header X-Proxc-Method $request_method;
        proxy_set_header X-Proxc-Remote-Addr $remote_addr;
        proxy_set_header X-Proxc-Scheme $scheme;
    }}

    location / {{
        mirror /_proxc_mirror;
        mirror_request_body on;
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


def normalize_hostname(value):
    if not value:
        return ""
    raw = value.strip().lower()
    if not raw:
        return ""

    if "." not in raw:
        if SUBDOMAIN_RE.fullmatch(raw):
            return f"{raw}.{BASE_DOMAIN}"
        return ""

    if raw.endswith(f".{BASE_DOMAIN}"):
        subdomain = raw[: -(len(BASE_DOMAIN) + 1)]
        if SUBDOMAIN_RE.fullmatch(subdomain):
            return raw
    return ""


def upsert_issued_host(hostname):
    with db_connect() as conn:
        conn.execute(
            "INSERT INTO issued_hosts (hostname, issued_at) VALUES (?, ?) ON CONFLICT(hostname) DO NOTHING",
            (hostname, int(time.time())),
        )


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

    upsert_issued_host(hostname)
    return hostname


def parse_register_payload(content_type, raw_body):
    body_text = raw_body.decode("utf-8", errors="replace")
    if "application/json" in (content_type or ""):
        data = json.loads(body_text or "{}")
        return data.get("subdomain", ""), data.get("authToken", "")

    form = parse_qs(body_text)
    subdomain = form.get("subdomain", [""])[0]
    auth_token = form.get("authToken", [""])[0]
    return subdomain, auth_token


def parse_form_or_json(content_type, raw_body):
    text = raw_body.decode("utf-8", errors="replace")
    if "application/json" in (content_type or ""):
        try:
            return json.loads(text or "{}")
        except json.JSONDecodeError:
            return {}

    parsed = parse_qs(text)
    output = {}
    for key, values in parsed.items():
        output[key] = values[0] if values else ""
    return output


def create_admin_session():
    token = secrets.token_urlsafe(32)
    expires_at = int(time.time()) + ADMIN_SESSION_TTL_SECONDS
    with SESSIONS_LOCK:
        SESSIONS[token] = expires_at
    return token, expires_at


def session_is_valid(token):
    if not token:
        return False
    now = int(time.time())
    with SESSIONS_LOCK:
        expires_at = SESSIONS.get(token)
        if not expires_at:
            return False
        if expires_at <= now:
            SESSIONS.pop(token, None)
            return False
        return True


def delete_session(token):
    if not token:
        return
    with SESSIONS_LOCK:
        SESSIONS.pop(token, None)


def parse_session_cookie(header_value):
    if not header_value:
        return ""
    jar = cookies.SimpleCookie()
    jar.load(header_value)
    morsel = jar.get(SESSION_COOKIE_NAME)
    return morsel.value if morsel else ""


def frps_api_get(path):
    url = FRPS_DASHBOARD_URL.rstrip("/") + path
    headers = {"Accept": "application/json"}
    if FRPS_DASHBOARD_USER or FRPS_DASHBOARD_PASS:
        pair = f"{FRPS_DASHBOARD_USER}:{FRPS_DASHBOARD_PASS}".encode("utf-8")
        headers["Authorization"] = "Basic " + base64.b64encode(pair).decode("ascii")

    req = Request(url, headers=headers)
    with urlopen(req, timeout=3) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def fetch_frps_connections():
    types = ["tcp", "udp", "http", "https", "tcpmux", "stcp", "sudp", "xtcp"]
    result = {
        "server": {},
        "proxies": [],
        "summary": {"total": 0, "online": 0},
    }
    try:
        result["server"] = frps_api_get("/api/serverinfo")
        for proxy_type in types:
            try:
                data = frps_api_get(f"/api/proxy/{proxy_type}")
            except (HTTPError, URLError, TimeoutError, ValueError):
                continue
            for proxy in data.get("proxies", []):
                entry = {
                    "name": proxy.get("name", ""),
                    "status": proxy.get("status", "unknown"),
                    "type": proxy_type,
                    "todayTrafficIn": proxy.get("todayTrafficIn", 0),
                    "todayTrafficOut": proxy.get("todayTrafficOut", 0),
                    "curConns": proxy.get("curConns", 0),
                    "lastStartTime": proxy.get("lastStartTime", ""),
                }
                result["proxies"].append(entry)

        result["summary"]["total"] = len(result["proxies"])
        result["summary"]["online"] = sum(1 for item in result["proxies"] if item["status"] == "online")
        return result, None
    except (HTTPError, URLError, TimeoutError, ValueError) as exc:
        return result, str(exc)


def start_capture(hostname, duration_minutes):
    now = int(time.time())
    expires_at = now + max(1, duration_minutes) * 60
    with db_connect() as conn:
        conn.execute(
            """
            INSERT INTO capture_sessions (hostname, enabled, expires_at, updated_at)
            VALUES (?, 1, ?, ?)
            ON CONFLICT(hostname)
            DO UPDATE SET enabled = 1, expires_at = excluded.expires_at, updated_at = excluded.updated_at
            """,
            (hostname, expires_at, now),
        )


def stop_capture(hostname):
    now = int(time.time())
    with db_connect() as conn:
        conn.execute(
            "UPDATE capture_sessions SET enabled = 0, updated_at = ? WHERE hostname = ?",
            (now, hostname),
        )


def capture_is_active(hostname):
    now = int(time.time())
    with db_connect() as conn:
        row = conn.execute(
            "SELECT enabled, expires_at FROM capture_sessions WHERE hostname = ?",
            (hostname,),
        ).fetchone()
        if not row:
            return False
        if row["enabled"] != 1:
            return False
        if row["expires_at"] <= now:
            conn.execute("UPDATE capture_sessions SET enabled = 0, updated_at = ? WHERE hostname = ?", (now, hostname))
            return False
        return True


def list_capture_sessions():
    with db_connect() as conn:
        return conn.execute(
            """
            SELECT hostname, enabled, expires_at, updated_at
            FROM capture_sessions
            ORDER BY hostname ASC
            """
        ).fetchall()


def list_recent_requests(limit=100):
    with db_connect() as conn:
        return conn.execute(
            """
            SELECT id, captured_at, hostname, method, path, query, remote_addr, scheme,
                   headers_json, body_text, body_truncated, body_bytes
            FROM captured_requests
            ORDER BY captured_at DESC
            LIMIT ?
            """,
            (max(1, min(limit, 500)),),
        ).fetchall()


def capture_request(hostname, method, path, query, remote_addr, scheme, headers_json, body_text, body_truncated, body_bytes):
    with db_connect() as conn:
        conn.execute(
            """
            INSERT INTO captured_requests (
                captured_at, hostname, method, path, query, remote_addr, scheme,
                headers_json, body_text, body_truncated, body_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                int(time.time()),
                hostname,
                method,
                path,
                query,
                remote_addr,
                scheme,
                headers_json,
                body_text,
                1 if body_truncated else 0,
                body_bytes,
            ),
        )


def read_request_body(handler):
    try:
        length = int(handler.headers.get("Content-Length", "0"))
    except ValueError:
        return None, "invalid_content_length"

    if length < 0:
        return None, "invalid_content_length"

    raw = handler.rfile.read(length)
    return raw, None


def html_page(title, body):
    return f"""<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\">
  <title>{html.escape(title)}</title>
  <style>
    body {{ font-family: sans-serif; margin: 24px; }}
    table {{ border-collapse: collapse; width: 100%; margin-top: 12px; }}
    th, td {{ border: 1px solid #ddd; padding: 8px; vertical-align: top; }}
    th {{ background: #f7f7f7; text-align: left; }}
    pre {{ white-space: pre-wrap; word-break: break-word; margin: 0; }}
    .row {{ display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }}
    .ok {{ color: #0a6d26; }}
    .err {{ color: #a10000; }}
    input[type=text], input[type=number], input[type=password] {{ padding: 6px; }}
    button {{ padding: 6px 10px; }}
  </style>
</head>
<body>
{body}
</body>
</html>
"""


class RegisterHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _send_html(self, status, text):
        raw = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def _require_admin(self, redirect_to_login=True):
        if not ADMIN_TOKEN:
            self._send_json(503, {"error": "admin_disabled", "details": "ADMIN_TOKEN is not set"})
            return False

        token = parse_session_cookie(self.headers.get("Cookie"))
        if session_is_valid(token):
            return True

        if redirect_to_login:
            self._redirect("/_proxc/admin/login")
        else:
            self._send_json(401, {"error": "unauthorized"})
        return False

    def _admin_dashboard(self, flash_message=""):
        connections, conn_error = fetch_frps_connections()
        sessions = list_capture_sessions()
        requests = list_recent_requests(limit=100)

        summary = connections.get("summary", {})
        total = int(summary.get("total", 0))
        online = int(summary.get("online", 0))

        msg_html = ""
        if flash_message:
            msg_html = f"<p class=\"ok\">{html.escape(flash_message)}</p>"

        conn_html = f"<p>FRPS Proxies: <strong>{online}</strong> online / <strong>{total}</strong> total.</p>"
        if conn_error:
            conn_html += f"<p class=\"err\">FRPS API error: {html.escape(conn_error)}</p>"

        proxies_rows = []
        for proxy in connections.get("proxies", []):
            proxies_rows.append(
                "<tr>"
                f"<td>{html.escape(proxy['name'])}</td>"
                f"<td>{html.escape(proxy['type'])}</td>"
                f"<td>{html.escape(proxy['status'])}</td>"
                f"<td>{int(proxy.get('curConns', 0))}</td>"
                f"<td>{int(proxy.get('todayTrafficIn', 0))}</td>"
                f"<td>{int(proxy.get('todayTrafficOut', 0))}</td>"
                "</tr>"
            )
        if not proxies_rows:
            proxies_rows.append("<tr><td colspan=\"6\">No proxy data.</td></tr>")

        session_rows = []
        now = int(time.time())
        for session in sessions:
            state = "enabled" if session["enabled"] == 1 and session["expires_at"] > now else "disabled"
            session_rows.append(
                "<tr>"
                f"<td>{html.escape(session['hostname'])}</td>"
                f"<td>{state}</td>"
                f"<td>{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(session['expires_at']))}</td>"
                "</tr>"
            )
        if not session_rows:
            session_rows.append("<tr><td colspan=\"3\">No capture sessions configured.</td></tr>")

        request_rows = []
        for row in requests:
            headers_text = row["headers_json"]
            if len(headers_text) > 2000:
                headers_text = headers_text[:2000] + " ..."

            body_text = row["body_text"] or ""
            if len(body_text) > 2000:
                body_text = body_text[:2000] + " ..."

            request_rows.append(
                "<tr>"
                f"<td>{row['id']}</td>"
                f"<td>{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(row['captured_at']))}</td>"
                f"<td>{html.escape(row['hostname'])}</td>"
                f"<td>{html.escape(row['method'])}</td>"
                f"<td><pre>{html.escape(row['path'])}</pre></td>"
                f"<td><pre>{html.escape(row['query'])}</pre></td>"
                f"<td><pre>{html.escape(headers_text)}</pre></td>"
                f"<td><pre>{html.escape(body_text)}</pre></td>"
                "</tr>"
            )
        if not request_rows:
            request_rows.append("<tr><td colspan=\"8\">No captured requests.</td></tr>")

        body = f"""
<h1>PROXC Admin Dashboard</h1>
{msg_html}
<p><a href=\"/_proxc/admin/logout\">Logout</a></p>

<h2>Capture Control</h2>
<div class=\"row\">
  <form method=\"post\" action=\"/_proxc/admin/capture/start\">
    <input type=\"text\" name=\"hostname\" placeholder=\"subdomain or full host\" required>
    <input type=\"number\" name=\"minutes\" min=\"1\" value=\"{CAPTURE_DEFAULT_DURATION_MINUTES}\" required>
    <button type=\"submit\">Start Capture</button>
  </form>
  <form method=\"post\" action=\"/_proxc/admin/capture/stop\">
    <input type=\"text\" name=\"hostname\" placeholder=\"subdomain or full host\" required>
    <button type=\"submit\">Stop Capture</button>
  </form>
</div>

<h2>FRPS Connections</h2>
{conn_html}
<table>
  <thead><tr><th>Name</th><th>Type</th><th>Status</th><th>Current Conns</th><th>Today In</th><th>Today Out</th></tr></thead>
  <tbody>
    {''.join(proxies_rows)}
  </tbody>
</table>

<h2>Capture Sessions</h2>
<table>
  <thead><tr><th>Hostname</th><th>State</th><th>Expires At</th></tr></thead>
  <tbody>
    {''.join(session_rows)}
  </tbody>
</table>

<h2>Recent Captured Requests</h2>
<table>
  <thead><tr><th>ID</th><th>Time</th><th>Host</th><th>Method</th><th>Path</th><th>Query</th><th>Headers</th><th>Body</th></tr></thead>
  <tbody>
    {''.join(request_rows)}
  </tbody>
</table>
"""
        self._send_html(200, html_page("PROXC Admin", body))

    def _handle_register(self):
        raw_body, read_error = read_request_body(self)
        if read_error:
            self._send_json(400, {"error": read_error})
            return

        try:
            subdomain, auth_token = parse_register_payload(self.headers.get("Content-Type", ""), raw_body)
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

    def _handle_admin_login_post(self):
        raw_body, read_error = read_request_body(self)
        if read_error:
            self._send_html(400, html_page("Login", "<p class='err'>Invalid request body.</p>"))
            return

        payload = parse_form_or_json(self.headers.get("Content-Type", ""), raw_body)
        token = str(payload.get("token", ""))
        if not ADMIN_TOKEN or token != ADMIN_TOKEN:
            self._send_html(401, html_page("Login", "<p class='err'>Invalid admin token.</p>"))
            return

        session_token, expires_at = create_admin_session()
        self.send_response(302)
        self.send_header("Location", "/_proxc/admin")
        self.send_header(
            "Set-Cookie",
            f"{SESSION_COOKIE_NAME}={session_token}; HttpOnly; Path=/_proxc/admin; Max-Age={max(0, expires_at - int(time.time()))}; SameSite=Strict",
        )
        self.end_headers()

    def _handle_admin_capture_start(self):
        if not self._require_admin():
            return

        raw_body, read_error = read_request_body(self)
        if read_error:
            self._admin_dashboard("Failed to parse request body")
            return

        payload = parse_form_or_json(self.headers.get("Content-Type", ""), raw_body)
        hostname = normalize_hostname(str(payload.get("hostname", "")))
        try:
            minutes = int(payload.get("minutes", CAPTURE_DEFAULT_DURATION_MINUTES))
        except (TypeError, ValueError):
            minutes = CAPTURE_DEFAULT_DURATION_MINUTES

        if not hostname:
            self._admin_dashboard("Invalid hostname/subdomain")
            return

        start_capture(hostname, max(1, minutes))
        self._admin_dashboard(f"Capture started for {hostname} ({max(1, minutes)} minutes)")

    def _handle_admin_capture_stop(self):
        if not self._require_admin():
            return

        raw_body, read_error = read_request_body(self)
        if read_error:
            self._admin_dashboard("Failed to parse request body")
            return

        payload = parse_form_or_json(self.headers.get("Content-Type", ""), raw_body)
        hostname = normalize_hostname(str(payload.get("hostname", "")))
        if not hostname:
            self._admin_dashboard("Invalid hostname/subdomain")
            return

        stop_capture(hostname)
        self._admin_dashboard(f"Capture stopped for {hostname}")

    def _handle_internal_mirror(self):
        if not MIRROR_SHARED_SECRET:
            self._send_json(503, {"error": "mirror_disabled"})
            return

        req_secret = self.headers.get("X-Proxc-Mirror-Secret", "")
        if req_secret != MIRROR_SHARED_SECRET:
            self._send_json(401, {"error": "unauthorized"})
            return

        raw_body, read_error = read_request_body(self)
        if read_error:
            self._send_json(400, {"error": read_error})
            return

        method = self.headers.get("X-Proxc-Method", "") or "UNKNOWN"
        hostname = normalize_hostname(self.headers.get("X-Proxc-Original-Host", ""))
        if not hostname:
            self._send_json(400, {"error": "invalid_hostname"})
            return

        if not capture_is_active(hostname):
            self._send_json(202, {"status": "ignored", "reason": "capture_inactive"})
            return

        uri = self.headers.get("X-Proxc-Original-Uri", "/")
        parsed = urlsplit(uri)
        path = parsed.path or "/"
        query = parsed.query or ""

        remote_addr = self.headers.get("X-Proxc-Remote-Addr", "")
        scheme = self.headers.get("X-Proxc-Scheme", "")

        body_bytes = len(raw_body)
        body_truncated = False
        if body_bytes > REQUEST_BODY_MAX_BYTES:
            raw_body = raw_body[:REQUEST_BODY_MAX_BYTES]
            body_truncated = True

        body_text = raw_body.decode("utf-8", errors="replace")

        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in {
                "x-proxc-mirror-secret",
                "x-proxc-original-host",
                "x-proxc-original-uri",
                "x-proxc-method",
                "x-proxc-remote-addr",
                "x-proxc-scheme",
                "content-length",
            }:
                continue
            headers[key] = value

        capture_request(
            hostname=hostname,
            method=method,
            path=path,
            query=query,
            remote_addr=remote_addr,
            scheme=scheme,
            headers_json=json.dumps(headers, ensure_ascii=True),
            body_text=body_text,
            body_truncated=body_truncated,
            body_bytes=body_bytes,
        )
        self._send_json(200, {"status": "captured", "hostname": hostname})

    def _render_login_page(self):
        body = """
<h1>PROXC Admin Login</h1>
<form method=\"post\" action=\"/_proxc/admin/login\">
  <input type=\"password\" name=\"token\" placeholder=\"Admin token\" required>
  <button type=\"submit\">Login</button>
</form>
"""
        self._send_html(200, html_page("PROXC Admin Login", body))

    def do_GET(self):
        maybe_cleanup_old_data()
        parsed = urlsplit(self.path)
        path = parsed.path

        if path == "/_proxc/admin/login":
            self._render_login_page()
            return

        if path == "/_proxc/admin/logout":
            token = parse_session_cookie(self.headers.get("Cookie"))
            delete_session(token)
            self.send_response(302)
            self.send_header("Location", "/_proxc/admin/login")
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE_NAME}=; HttpOnly; Path=/_proxc/admin; Max-Age=0; SameSite=Strict",
            )
            self.end_headers()
            return

        if path == "/_proxc/admin":
            if not self._require_admin():
                return
            self._admin_dashboard()
            return

        if path == "/_proxc/admin/connections":
            if not self._require_admin(redirect_to_login=False):
                return
            data, err = fetch_frps_connections()
            self._send_json(200, {"data": data, "error": err})
            return

        if path == "/_proxc/admin/requests":
            if not self._require_admin(redirect_to_login=False):
                return
            rows = list_recent_requests(limit=200)
            items = []
            for row in rows:
                items.append(
                    {
                        "id": row["id"],
                        "captured_at": row["captured_at"],
                        "hostname": row["hostname"],
                        "method": row["method"],
                        "path": row["path"],
                        "query": row["query"],
                        "remote_addr": row["remote_addr"],
                        "scheme": row["scheme"],
                        "headers": json.loads(row["headers_json"]),
                        "body_text": row["body_text"],
                        "body_truncated": bool(row["body_truncated"]),
                        "body_bytes": row["body_bytes"],
                    }
                )
            self._send_json(200, {"requests": items})
            return

        self._send_json(404, {"error": "not_found"})

    def do_POST(self):
        maybe_cleanup_old_data()
        parsed = urlsplit(self.path)
        path = parsed.path

        if path == "/_proxc/register":
            self._handle_register()
            return

        if path == "/_proxc/admin/login":
            self._handle_admin_login_post()
            return

        if path == "/_proxc/admin/capture/start":
            self._handle_admin_capture_start()
            return

        if path == "/_proxc/admin/capture/stop":
            self._handle_admin_capture_stop()
            return

        if path == "/_proxc/internal/mirror":
            self._handle_internal_mirror()
            return

        self._send_json(404, {"error": "not_found"})

    def log_message(self, _format, *_args):  # ty:ignore[invalid-method-override]
        return


if __name__ == "__main__":
    init_db()
    maybe_cleanup_old_data()
    server = ThreadingHTTPServer(("127.0.0.1", REGISTER_PORT), RegisterHandler)
    server.serve_forever()
