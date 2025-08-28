# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Saeed Almansoori
"""
Remote Access Agent
- Watches 'EnableRemoteAccess' param
- Installs Tailscale if missing
- Runs 'tailscaled' and 'tailscale up'
- Captures login URL and stores it in 'RemoteAccessLoginURL'
- On disable: 'tailscale down' and clears URL
"""
import os, re, subprocess, time, shlex, pathlib, sys

PARAMS_DIR = os.environ.get("PARAMS_DIR", "/data/params/d")
P_ENABLE = "EnableRemoteAccess"
P_URL    = "RemoteAccessLoginURL"

def ppath(name): return os.path.join(PARAMS_DIR, name)

def read_param(name, default=b""):
  try:
    with open(ppath(name), "rb") as f: return f.read()
  except Exception: return default

def write_param(name, data: bytes):
  pathlib.Path(PARAMS_DIR).mkdir(parents=True, exist_ok=True)
  with open(ppath(name), "wb") as f: f.write(data)

def shell(cmd, capture=False):
  if capture:
    return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
  return subprocess.run(cmd, shell=True, check=False)

def ensure_tailscale():
  # install if missing
  code = subprocess.call("command -v tailscale >/dev/null 2>&1", shell=True)
  if code != 0:
    # silent install; safe if already present
    shell("curl -fsSL https://tailscale.com/install.sh | sh")
  # ensure daemon
  shell("pgrep -x tailscaled >/dev/null || nohup tailscaled >/dev/null 2>&1 &")

def extract_login_url(output: str) -> str:
  # tailscale up usually prints a URL like: https://login.tailscale.com/a/abcdef...
  m = re.search(r'https?://\S+', output)
  return m.group(0) if m else ""

def bring_up():
  ensure_tailscale()
  # Try to reset and bring up; capture URL if needs-login
  out = shell("tailscale up --ssh --reset 2>&1 || true", capture=True)
  url = extract_login_url(out)
  if not url:
    # already logged in OR another message; query status for URL in pending state
    st = shell("tailscale status 2>&1 || true", capture=True)
    u2 = extract_login_url(st)
    url = u2 or url
  write_param(P_URL, url.encode() if url else b"")
  return url

def bring_down():
  shell("tailscale down >/dev/null 2>&1 || true")
  write_param(P_URL, b"")

def main():
  last = None
  while True:
    v = read_param(P_ENABLE, b"0")
    on = (v == b"1")
    if on != last:
      if on:
        bring_up()
      else:
        bring_down()
      last = on
    time.sleep(2)

if __name__ == "__main__":
  try:
    main()
  except KeyboardInterrupt:
    sys.exit(0)
