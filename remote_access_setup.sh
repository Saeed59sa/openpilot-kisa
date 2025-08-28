#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Saeed Almansoori
#
# Remote Access bootstrapper using Tailscale.
# - Installs prerequisites if missing
# - Installs/starts tailscaled
# - Brings the node up (interactive auth URL or with --authkey)
# - Prints status and reachable IP(s)
#
# Usage:
#   bash remote_access_setup.sh [--authkey TSKEY...] [--ssh] [--hostname NAME]
#                               [--advertise-exit-node] [--status] [--logout]
#                               [--stop] [--start] [--uninstall]
#
# Notes:
# - To keep UI wording generic, logs say "Remote Access" even though Tailscale is used under the hood.
# - If no --authkey is provided, you'll get a login URL to share with the admin to approve the device.

set -euo pipefail

SIGNATURE="Saeed Almansoori"
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[Remote Access] Elevated privileges required. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

log()   { echo "[Remote Access] $*"; }
warn()  { echo "[Remote Access][WARN] $*" >&2; }
fail()  { echo "[Remote Access][ERROR] $*" >&2; exit 1; }

PM=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM="apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then PM="dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then PM="yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then PM="pacman"; return; fi
  PM="unknown"
}

pm_install() {
  case "$PM" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) warn "Unknown package manager. Skipping package install for: $*";;
  esac
}

ensure_bin() {
  local bin="$1" pkg="${2:-$1}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "Installing dependency: $bin"
    pm_install "$pkg" || warn "Could not install $pkg; continuing..."
  fi
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    log "Tailscale already installed."
    return
  fi
  log "Installing Tailscale via official installer..."
  # Use official one-line install (covers most distros)
  # Ref: https://tailscale.com/download
  curl -fsSL https://tailscale.com/install.sh | sh
  if ! command -v tailscaled >/dev/null 2>&1; then
    fail "tailscaled not found after install."
  fi
}

start_daemon() {
  # Prefer systemd; otherwise run a background daemon
  if command -v systemctl >/dev/null 2>&1; then
    log "Enabling and starting tailscaled (systemd)..."
    systemctl enable --now tailscaled
  else
    log "Starting tailscaled in userspace (no systemd)..."
    # Create state/socket dirs if needed
    mkdir -p /var/lib/tailscale /run/tailscale
    if pgrep -x tailscaled >/dev/null 2>&1; then
      log "tailscaled already running."
    else
      nohup tailscaled --state=/var/lib/tailscale/tailscaled.state \
                       --socket=/run/tailscale/tailscaled.sock \
                       --port 41641 \
                       >/var/log/tailscaled.log 2>&1 &
      sleep 1
    fi
  fi
}

bring_up() {
  local args=()
  local want_ssh="false"
  local advertise_exit="false"
  local hostname_arg=""
  local authkey="${RA_AUTHKEY:-}"

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh) want_ssh="true"; shift;;
      --advertise-exit-node) advertise_exit="true"; shift;;
      --hostname) hostname_arg="$2"; shift 2;;
      --authkey) authkey="$2"; shift 2;;
      *) break;;
    esac
  done

  [[ -n "${hostname_arg}" ]] && args+=(--hostname "${hostname_arg}")
  [[ "${want_ssh}" == "true" ]] && args+=(--ssh)
  [[ "${advertise_exit}" == "true" ]] && args+=(--advertise-exit-node)

  if [[ -n "${authkey}" ]]; then
    log "Bringing Remote Access up with provided auth key (non-interactive)..."
    tailscale up --authkey="${authkey}" "${args[@]}"
  else
    log "Bringing Remote Access up (interactive)… you will get a login URL:"
    # Capture output to extract login URL
    set +e
    TS_OUT="$( (tailscale up "${args[@]}") 2>&1 )"
    TS_CODE=$?
    set -e

    # Extract URL line if present
    AUTH_URL="$(echo "$TS_OUT" | grep -Eo 'https://login\.tailscale\.com/[a-zA-Z0-9/_?=&\-%]+' | head -n1 || true)"
    if [[ -n "$AUTH_URL" ]]; then
      echo
      echo "-----------------------------------------------"
      echo " Remote Access login URL (share with admin):"
      echo " $AUTH_URL"
      echo "-----------------------------------------------"
      echo
    fi

    if [[ $TS_CODE -ne 0 ]]; then
      echo "$TS_OUT"
      fail "tailscale up failed (code $TS_CODE)."
    fi
  fi
}

cmd_status() {
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale is not installed."
    return
  fi
  log "Status:"
  tailscale status || true
  echo
  log "Device addresses:"
  tailscale ip -4 || true
  tailscale ip -6 || true
}

cmd_logout() {
  log "Logging out Remote Access (tailscale logout)…"
  tailscale logout || true
}

cmd_stop() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop tailscaled || true
  else
    pkill -x tailscaled || true
  fi
  log "Remote Access stopped."
}

cmd_start() {
  start_daemon
  log "Remote Access started."
}

cmd_uninstall() {
  cmd_stop || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y tailscale || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf remove -y tailscale || true
  elif command -v yum >/dev/null 2>&1; then
    yum remove -y tailscale || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -R --noconfirm tailscale || true
  fi
  rm -rf /var/lib/tailscale /run/tailscale /var/log/tailscaled.log || true
  log "Remote Access uninstalled."
}

print_help() {
  cat <<EOF
Remote Access (Tailscale) bootstrap — ${SIGNATURE}

Usage:
  $0 [--authkey tskey-XXXX] [--ssh] [--hostname NAME] [--advertise-exit-node]
     [--status] [--logout] [--stop] [--start] [--uninstall]

Env:
  RA_AUTHKEY   Optional auth key (same as --authkey).

Examples:
  $0 --ssh
  RA_AUTHKEY=tskey-XXXX $0 --hostname my-node --ssh
  $0 --status

EOF
}

main() {
  local do_status=false do_logout=false do_stop=false do_start=false do_uninstall=false
  local pass_args=()

  # Quick command-only paths (no root needed for help)
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help; exit 0
  fi

  # Parse top-level command flags
  for arg in "$@"; do
    case "$arg" in
      --status) do_status=true;;
      --logout) do_logout=true;;
      --stop) do_stop=true;;
      --start) do_start=true;;
      --uninstall) do_uninstall=true;;
    esac
  done

  # Some commands don't need root
  if $do_status; then cmd_status; exit 0; fi

  need_root "$@"

  detect_pm
  ensure_bin curl curl

  if [[ "$do_uninstall" == "true" ]]; then cmd_uninstall; exit 0; fi

  install_tailscale
  start_daemon

  if [[ "$do_logout" == "true" ]]; then cmd_logout; exit 0; fi
  if [[ "$do_stop"   == "true" ]]; then cmd_stop;   exit 0; fi
  if [[ "$do_start"  == "true" ]]; then cmd_start;  exit 0; fi

  # Default action: bring the node up
  bring_up "$@"
  cmd_status
  log "Done. (${SIGNATURE})"
}

main "$@"
