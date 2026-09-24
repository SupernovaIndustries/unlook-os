#!/usr/bin/python3
"""Unlook setup page: choose the office Wi-Fi from the phone, on the hotspot.

Served only on the hotspot address (unlook-setup.socket, FreeBind, firewall:
hotspot interface only). Standard library only. All changes go through
`unlook-wifi` with a fixed argv and the secrets on stdin; this process holds no
capability (see unlook-setup.service). Owner decision: docs/OS.md §9.
"""

import hashlib
import hmac
import html
import os
import secrets
import socket
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

WIFI = "/usr/sbin/unlook-wifi"
CREDS = "/usr/sbin/unlook-credentials"
HOST = os.environ.get("UNLOOK_SETUP_HOST", "10.42.0.1")
PORT = int(os.environ.get("UNLOOK_SETUP_PORT", "80"))
MAX_BODY = 4096
TOKEN = secrets.token_urlsafe(32)
SD_LISTEN_FDS_START = 3


def run(argv, stdin=None, timeout=20):
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


def kv(argv):
    rc, out, _ = run(argv)
    d = {}
    if rc == 0:
        for line in out.splitlines():
            k, sep, v = line.partition("=")
            if sep:
                d[k] = v
    return d


def networks():
    rc, out, _ = run([WIFI, "list"])
    nets = []
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[0].isdigit() and parts[2]:
                nets.append((int(parts[0]), parts[1], parts[2]))
    return nets


def valid_ssid(s):
    b = s.encode("utf-8")
    return 1 <= len(b) <= 32 and not any(c < 0x20 or c == 0x7F for c in b)


def valid_psk(p):
    if p == "":
        return True
    if len(p) == 64 and all(c in "0123456789abcdefABCDEF" for c in p):
        return True
    return 8 <= len(p) <= 63 and all(0x20 <= ord(c) <= 0x7E for c in p)


e = html.escape

STYLE = """
body{font-family:system-ui,sans-serif;margin:0;background:#f4f5f7;color:#16181d}
main{max-width:34rem;margin:0 auto;padding:1rem}
h1{font-size:1.4rem}h2{font-size:1.05rem;margin-top:1.6rem}
section{background:#fff;border-radius:.6rem;padding:1rem;margin:.8rem 0;box-shadow:0 1px 2px #0002}
label{display:block;margin:.6rem 0 .2rem;font-weight:600}
select,input{width:100%;box-sizing:border-box;font-size:1rem;padding:.6rem;border:1px solid #bbb;border-radius:.4rem}
button{margin-top:1rem;width:100%;font-size:1rem;padding:.8rem;border:0;border-radius:.4rem;background:#1a56db;color:#fff}
button.alt{background:#555}
code,.secret{font-family:ui-monospace,monospace;background:#eef;padding:.1rem .3rem;border-radius:.2rem;word-break:break-all}
.warn{color:#8a1c1c}.ok{color:#1c6b2a}.small{font-size:.85rem;color:#555}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}section{background:#1d1f24}
select,input{background:#111;color:#eee;border-color:#444}code,.secret{background:#2a2d40}.small{color:#aaa}}
"""


def page(body):
    return (
        "<!doctype html><html lang=it><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Unlook setup</title><style>" + STYLE + "</style></head><body><main>" + body + "</main></body></html>"
    )


def home(msg=""):
    c = kv([CREDS, "--kv"])
    s = kv([WIFI, "status", "--kv"])
    nets = networks()
    out = ["<h1>Unlook &middot; " + e(c.get("unit", "")) + "</h1>"]
    if msg:
        out.append("<section>" + msg + "</section>")
    state = s.get("state", "")
    if state == "failed" or state == "fallback":
        out.append("<section class=warn>Ultimo tentativo: " + e(s.get("ssid", "")) + " &mdash; " + e(s.get("error", "")) + "</section>")
    elif s.get("connection") not in (None, "", "--", "unlook-ap"):
        out.append("<section class=ok>Collegato a " + e(s.get("connection", "")) + "</section>")

    out.append("<section><h2>Wi-Fi dell'ufficio</h2><form method=post action=/wifi>")
    out.append("<input type=hidden name=token value='" + e(TOKEN) + "'>")
    out.append("<label for=ssid>Rete</label><select id=ssid name=ssid>")
    for sig, sec, ssid in nets:
        tag = "aperta" if sec == "open" else sec
        out.append("<option value='" + e(ssid) + "'>" + e(ssid) + " &middot; " + str(sig) + "% &middot; " + e(tag) + "</option>")
    out.append("<option value=''>Altra rete (scrivi il nome qui sotto)</option></select>")
    out.append("<label for=other>Nome rete (solo per \"Altra rete\")</label><input id=other name=other maxlength=32 autocomplete=off>")
    out.append("<label for=psk>Password</label><input id=psk name=psk type=password maxlength=64 autocomplete=off>")
    out.append("<p class=small>Lascia vuota la password solo per le reti aperte.</p>")
    out.append("<button type=submit>Collega lo scanner</button></form>")
    if not nets:
        out.append("<p class=small>Nessuna rete rilevata all'avvio: scrivi il nome della rete in \"Altra rete\".</p>")
    out.append("</section>")

    out.append("<section><h2>Accesso SSH</h2><p>Utente <code>" + e(c.get("user", "")) + "</code></p>")
    if c.get("password"):
        out.append("<p>Password <span class=secret>" + e(c["password"]) + "</span></p>"
                   "<p class=small>Password di questa unit&agrave;. Annotala; per cambiarla: <code>sudo unlook-ssh passwd</code>.</p>")
    else:
        out.append("<p>Password: " + e(c.get("password_note", "")) + "</p>")
    out.append("<p>Da questo hotspot: <code>ssh " + e(c.get("user", "")) + "@" + e(HOST) + "</code><br>"
               "Dopo il Wi-Fi: <code>ssh " + e(c.get("user", "")) + "@" + e(c.get("lan_name", "")) + "</code></p></section>")
    out.append("<section class=small>Dopo il collegamento lo scanner lascia l'hotspot e il telefono si disconnette. "
               "Se la rete non risponde, l'hotspot torna da solo entro qualche minuto con questa pagina.</section>")
    return page("".join(out))


def switching(ssid, lan):
    return page(
        "<h1>Collegamento in corso</h1><section>Lo scanner si sta collegando a <b>" + e(ssid) + "</b>. "
        "Tra pochi secondi l'hotspot si spegne: ricollega il telefono alla tua rete.</section>"
        "<section>Poi: <code>ssh " + e(lan) + "</code><br>"
        "Se la password era sbagliata l'hotspot torna da solo e qui vedrai l'errore.</section>"
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "unlook-setup"
    sys_version = ""
    timeout = 15

    def log_message(self, fmt, *args):  # journal via stderr, no client data
        cmd = getattr(self, "command", None) or "-"
        path = (getattr(self, "path", None) or "-").split("?")[0][:64]
        sys.stderr.write("setup: %s %s\n" % (cmd, path))

    def host_ok(self):
        # Only the literal hotspot address: blocks DNS rebinding.
        h = (self.headers.get("Host") or "").strip()
        return h in (HOST, "%s:%d" % (HOST, PORT))

    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.host_ok():
            return self.send(421, page("<h1>Apri http://" + e(HOST) + "/</h1>"))
        if self.path.split("?")[0] != "/":
            return self.send(404, page("<h1>Pagina non trovata</h1><p><a href=/>Setup</a></p>"))
        self.send(200, home())

    def do_POST(self):
        if not self.host_ok() or self.path != "/wifi":
            return self.send(403, page("<h1>Richiesta rifiutata</h1>"))
        origin = self.headers.get("Origin")
        if origin and origin not in ("http://" + HOST, "http://%s:%d" % (HOST, PORT)):
            return self.send(403, page("<h1>Richiesta rifiutata</h1>"))
        try:
            n = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            return self.send(413, page("<h1>Richiesta troppo grande</h1>"))
        try:
            raw = self.rfile.read(n).decode("utf-8", "strict") if n else ""
            form = urllib.parse.parse_qs(raw, keep_blank_values=True, strict_parsing=bool(raw), max_num_fields=8)
        except (ValueError, OSError):
            return self.send(400, page("<h1>Richiesta non valida</h1>"))
        get = lambda k: (form.get(k) or [""])[0]
        if not hmac.compare_digest(hashlib.sha256(get("token").encode()).digest(), hashlib.sha256(TOKEN.encode()).digest()):
            return self.send(403, home("<span class=warn>Pagina scaduta: riprova.</span>"))
        ssid = get("other").strip() if get("ssid") == "" else get("ssid")
        psk = get("psk")
        if not valid_ssid(ssid):
            return self.send(400, home("<span class=warn>Nome rete non valido (1-32 byte).</span>"))
        if not valid_psk(psk):
            return self.send(400, home("<span class=warn>Password non valida: 8-63 caratteri (o 64 cifre esadecimali), vuota solo per reti aperte.</span>"))
        rc, _, err = run([WIFI, "set"], stdin=ssid + "\n" + psk + "\n", timeout=20)
        if rc != 0:
            return self.send(500, home("<span class=warn>Impossibile salvare la rete: " + e(err.strip()[-200:]) + "</span>"))
        c = kv([CREDS, "--kv"])
        self.send(200, switching(ssid, c.get("user", "") + "@" + c.get("lan_name", "")))


def main():
    server = HTTPServer((HOST, PORT), Handler, bind_and_activate=False)
    if os.environ.get("LISTEN_PID") == str(os.getpid()) and os.environ.get("LISTEN_FDS") == "1":
        server.socket.close()
        server.socket = socket.socket(fileno=SD_LISTEN_FDS_START)
    else:
        sys.stderr.write("setup: not socket-activated (unlook-setup.socket); refusing to bind myself\n")
        return 1
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
