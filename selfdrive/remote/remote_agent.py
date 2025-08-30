# SPDX-License-Identifier: MIT
"""
Remote Access Agent
- Watches 'EnableRemoteAccess' param
- Installs and manages Tailscale
- Captures login URL and stores it in 'RemoteAccessLoginURL'
- Logs out first so each enable produces a fresh login link
"""
import os
import pathlib
import re
import subprocess
import time

PARAMS_DIR = os.environ.get("PARAMS_DIR", "/data/params/d")
P_ENABLE = "EnableRemoteAccess"
P_URL = "RemoteAccessLoginURL"

def _ppath(name: str) -> str:
    return os.path.join(PARAMS_DIR, name)

def read_param(name: str, default: bytes = b"") -> bytes:
    try:
        with open(_ppath(name), "rb") as f:
            return f.read()
    except Exception:
        return default

def write_param(name: str, data: bytes) -> None:
    pathlib.Path(PARAMS_DIR).mkdir(parents=True, exist_ok=True)
    with open(_ppath(name), "wb") as f:
        f.write(data)

def shell(cmd: str, capture: bool = False) -> str:
    if capture:
        res = subprocess.run(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        return res.stdout
    subprocess.run(cmd, shell=True, check=False)
    return ""

def ensure_tailscale() -> None:
    if subprocess.call("command -v tailscale >/dev/null 2>&1", shell=True) != 0:
        shell("curl -fsSL https://tailscale.com/install.sh | sh")
    shell("pgrep -x tailscaled >/dev/null || nohup tailscaled >/dev/null 2>&1 &")

def extract_login_url(output: str) -> str:
    match = re.search(r"https?://\S+", output)
    return match.group(0) if match else ""

def bring_up() -> None:
    ensure_tailscale()
    # Log out first so each enable generates a fresh login URL
    shell("tailscale logout >/dev/null 2>&1 || true")
    out = shell("tailscale up --ssh --reset 2>&1 || true", capture=True)
    url = extract_login_url(out)
    if not url:
        status = shell("tailscale status 2>&1 || true", capture=True)
        url = extract_login_url(status)
    write_param(P_URL, url.encode() if url else b"")

def bring_down() -> None:
    shell("tailscale down >/dev/null 2>&1 || true")
    write_param(P_URL, b"")

def main() -> None:
    last = None
    while True:
        enabled = read_param(P_ENABLE, b"0") == b"1"
        if enabled != last:
            if enabled:
                bring_up()
            else:
                bring_down()
            last = enabled
        time.sleep(2)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
