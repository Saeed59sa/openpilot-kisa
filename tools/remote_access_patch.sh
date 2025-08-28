#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Saeed Almansoori
#
# Remote Access one-shot patcher for SDpilot/OpenPilot repos.
# - Adds UI toggle under Network
# - Adds params: EnableRemoteAccess (bool), RemoteAccessLoginURL (text)
# - Adds remote agent process to manager
# - Creates a tiny daemon to manage Tailscale and capture login link
#
# Usage:
#   bash tools/remote_access_patch.sh
#
# Notes:
# - Safe to run multiple times.
# - If your repo paths differ, adjust the PATH HINTS section.

set -euo pipefail

### ───────────────────── PATH HINTS ─────────────────────
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$ROOT_DIR"
[ -d selfdrive ] || { echo "ERROR: run from repo root (selfdrive/ not found)"; exit 1; }

UI_SETTINGS_CPP="selfdrive/ui/qt/offroad/settings.cc"
PARAMS_PY="common/params.py"
PROC_CFG_PY="selfdrive/manager/process_config.py"
REMOTE_DIR="selfdrive/remote"
TOOLS_DIR="tools/remote_access"
mkdir -p "$REMOTE_DIR" "$TOOLS_DIR"

### ───────────────────── HELPERS ─────────────────────
ensure_line() {
  local file="$1"; shift
  local needle="$1"; shift
  grep -Fq "$needle" "$file" || echo "$needle" >> "$file"
}

apply_py_block_after() {
  local file="$1"; local anchor="$2"; local block="$3"
  if ! grep -Fq "$anchor" "$file"; then
    echo "WARN: anchor not found in $file; appending block to end."
    printf "\n%s\n" "$block" >> "$file"
    return
  fi
  if grep -Fq "# BEGIN_REMOTE_ACCESS" "$file"; then
    echo "INFO: block already exists in $file"
    return
  fi
  awk -v a="$anchor" -v b="$block" '
    BEGIN{printed=0}
    {print $0}
    $0 ~ a && !printed { print ""; print b; print ""; printed=1 }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

### ───────────────────── PARAMS ─────────────────────
if [ -f "$PARAMS_PY" ]; then
  if ! grep -Fq "EnableRemoteAccess" "$PARAMS_PY"; then
    cat >> "$PARAMS_PY" <<'PY'
# BEGIN_REMOTE_ACCESS  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
# Remote Access params
try:
  _params_types  # hint: some trees use PARAMS or _params_types; we guard both
except NameError:
  pass

# Generic registries seen across forks
for _name, _ptype, _default in [
  ("EnableRemoteAccess", "bool", b"0"),
  ("RemoteAccessLoginURL", "bytes", b""),
]:
  try:
    # OpenPilot style
    if 'keys' in globals() and isinstance(keys, dict) and _name not in keys:
      keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    # Alternate registry (_keys or _params_types)
    if '_keys' in globals() and isinstance(_keys, dict) and _name not in _keys:
      _keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    if '_params_types' in globals() and isinstance(_params_types, dict) and _name not in _params_types:
      _params_types[_name] = _ptype
      if '_default_values' in globals() and isinstance(_default_values, dict):
        _default_values[_name] = _default
  except Exception:
    pass
# END_REMOTE_ACCESS
PY
    echo "Added Remote Access params to $PARAMS_PY"
  else
    echo "Params already patched."
  fi
else
  echo "WARN: $PARAMS_PY not found. Skipping params registry patch."
fi

### ───────────────────── REMOTE AGENT ─────────────────────
cat > "$REMOTE_DIR/remote_agent.py" <<'PY'
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
PY
echo "Wrote $REMOTE_DIR/remote_agent.py"

### ───────────────────── MANAGER PROCESS ─────────────────────
if [ -f "$PROC_CFG_PY" ]; then
  if ! grep -Fq "remote_agent.py" "$PROC_CFG_PY"; then
    cat >> "$PROC_CFG_PY" <<'PY'

# BEGIN_REMOTE_ACCESS  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
try:
  from selfdrive.manager.process_config import managed_processes  # self import guard (varies by trees)
except Exception:
  pass

# Register remote agent if managed_processes exists
try:
  if isinstance(managed_processes, dict) and "remoteAgent" not in managed_processes:
    managed_processes["remoteAgent"] = {
      "proc": ["python3", "selfdrive/remote/remote_agent.py"],
      "enable": True,
      "sigkill": True,
    }
except Exception:
  pass
# END_REMOTE_ACCESS
PY
    echo "Patched manager process config."
  else
    echo "Manager process already patched."
  fi
else
  echo "WARN: $PROC_CFG_PY not found. Skipping manager patch."
fi

### ───────────────────── UI (NETWORK SETTINGS) ─────────────────────
if [ -f "$UI_SETTINGS_CPP" ]; then
  if ! grep -Fq "EnableRemoteAccess" "$UI_SETTINGS_CPP"; then
    cat >> "$UI_SETTINGS_CPP" <<'CPP'

// BEGIN_REMOTE_ACCESS  // SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
// Minimal UI toggle under Network + read-only field showing login URL
// Works with Param "EnableRemoteAccess" (bool) and "RemoteAccessLoginURL" (bytes)

#include "selfdrive/common/params.h"
#include <QHBoxLayout>
#include <QClipboard>

class RemoteAccessWidget : public QWidget {
  Q_OBJECT
public:
  RemoteAccessWidget(QWidget *parent=nullptr) : QWidget(parent) {
    auto *lay = new QVBoxLayout(this);
    toggle_ = new ParamControl("EnableRemoteAccess", tr("Remote Access"),
      tr("Enable secure remote access for support and maintenance."), "");
    lay->addWidget(toggle_);

    auto *h = new QHBoxLayout();
    url_ = new LabelControl(tr("Login Link"), "");
    url_->setWordWrap(true);
    auto *copyBtn = new QPushButton(tr("Copy"));
    connect(copyBtn, &QPushButton::clicked, this, [this](){
      QClipboard *cb = QGuiApplication::clipboard();
      cb->setText(url_->text());
    });
    auto *w = new QWidget(this);
    auto *inner = new QHBoxLayout(w);
    inner->addWidget(url_, 1);
    inner->addWidget(copyBtn, 0);
    lay->addWidget(w);

    timer_ = new QTimer(this);
    connect(timer_, &QTimer::timeout, this, &RemoteAccessWidget::refreshURL);
    timer_->start(1500);
    refreshURL();
  }
private slots:
  void refreshURL() {
    Params p;
    auto s = QString::fromStdString(p.get("RemoteAccessLoginURL"));
    url_->setText(s);
  }
private:
  ParamControl *toggle_ = nullptr;
  LabelControl *url_ = nullptr;
  QTimer *timer_ = nullptr;
};

// Hook into Network panel construction:
// Find your networking panel and add: `lay->addWidget(new RemoteAccessWidget(this));`
CPP
    echo "Appended Remote Access UI helper to $UI_SETTINGS_CPP"
  else
    echo "UI helper already present."
  fi

  # Try to auto-insert widget into the Network panel if a common anchor is found
  ANCHOR='// Network settings end anchor'
  if grep -Fq "$ANCHOR" "$UI_SETTINGS_CPP"; then
    apply_py_block_after "$UI_SETTINGS_CPP" "$ANCHOR" $'// Inserted by Remote Access patch\nlay->addWidget(new RemoteAccessWidget(this));\n'
    echo "Injected RemoteAccessWidget into Network panel."
  else
    echo "NOTE: Add widget manually in Network panel constructor:\n  lay->addWidget(new RemoteAccessWidget(this));"
  fi
else
  echo "WARN: $UI_SETTINGS_CPP not found. Add the RemoteAccessWidget include & widget call manually."
fi

### ───────────────────── DEV TOOL (manual toggle/test) ─────────────────────
cat > "$TOOLS_DIR/remote_ctl.sh" <<'SH'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# (c) 2025 Saeed Almansoori
set -euo pipefail
PARAMS_DIR="${PARAMS_DIR:-/data/params/d}"
mkdir -p "$PARAMS_DIR"
case "${1:-}" in
  enable)  echo -n 1 > "$PARAMS_DIR/EnableRemoteAccess" ;;
  disable) echo -n 0 > "$PARAMS_DIR/EnableRemoteAccess" ;;
  status)
    s="$(cat "$PARAMS_DIR/EnableRemoteAccess" 2>/dev/null || echo 0)"
    url="$(cat "$PARAMS_DIR/RemoteAccessLoginURL" 2>/dev/null || true)"
    echo "EnableRemoteAccess=$s"
    [ -n "$url" ] && echo "LoginURL=$url" || echo "LoginURL=<empty>"
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    ;;
esac
SH
chmod +x "$TOOLS_DIR/remote_ctl.sh"
echo "Wrote $TOOLS_DIR/remote_ctl.sh"

### ───────────────────── DONE ─────────────────────
echo "✅ Remote Access patch applied."
echo "- Build UI and run; under Network you should see: Remote Access toggle + Login Link."
echo "- You can test without UI: tools/remote_access/remote_ctl.sh enable|status|disable"
