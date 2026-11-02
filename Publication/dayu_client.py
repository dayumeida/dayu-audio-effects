"""Dayu publishing client: credentials stay in memory and curl stdin only."""
from pathlib import Path
import base64
import json
import re
import subprocess
import tempfile

BASE = "https://dayu.media"


def _auth_config():
    meta = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "dayu-article-publisher"], capture_output=True, text=True, check=True)
    match = re.search(r'"acct"<blob>="([^"\n]*)"', meta.stdout + meta.stderr)
    if not match:
        raise RuntimeError("Connected publisher account metadata is unavailable")
    username = match.group(1)
    secret = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "dayu-article-publisher", "-w"], capture_output=True, text=True, check=True).stdout.strip()
    token = base64.b64encode((username + ":" + secret).encode()).decode()
    return 'header = "Authorization: Basic ' + token + '"\n'


def request(method, path, payload=None, files=None, key=None, timeout=35):
    if not path.startswith("/wp-json/") or "\n" in path:
        raise ValueError("Only this site's WordPress routes are allowed")
    args = ["/usr/bin/curl", "--disable", "--silent", "--show-error", "--config", "-", "--proto", "=https", "--connect-timeout", "8", "--max-time", str(timeout), "--request", method, "--header", "Accept: application/json", "--write-out", "\n%{http_code}"]
    if key:
        if not re.fullmatch(r"[A-Za-z0-9._-]{8,100}", key):
            raise ValueError("Invalid idempotency key")
        args += ["--header", "Idempotency-Key: " + key]
    temporary = None
    try:
        if payload is not None:
            temporary = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json", delete=False)
            json.dump(payload, temporary, ensure_ascii=False)
            temporary.close()
            if files:
                args += ["--form", "payload=<" + temporary.name + ";type=application/json"]
            else:
                args += ["--header", "Content-Type: application/json", "--data-binary", "@" + temporary.name]
        for role, item in (files or {}).items():
            path_value, mime_type = item
            path_value = str(Path(path_value).resolve())
            if role not in {"package", "cover", "video", "video_cover", "file"} or '"' in path_value:
                raise ValueError("Unexpected upload role or path")
            args += ["--form", role + '=@"' + path_value + '";type=' + mime_type]
        args += [BASE + path]
        result = subprocess.run(args, input=_auth_config(), capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("curl transport failed: " + str(result.returncode) + " " + result.stderr[:300])
        body, code = result.stdout.rsplit("\n", 1)
        return int(code), json.loads(body)
    finally:
        if temporary:
            Path(temporary.name).unlink(missing_ok=True)
