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
