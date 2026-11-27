#!/usr/bin/env bash
# =============================================================================
#  CloudFRP Web Panel - unified launcher (Linux / macOS / WSL)
#  Starts the canonical backend: webpanel/server.py (Flask, :3592)
#
#  Usage:
#    ./start.sh                       start web panel (foreground)
#    ./start.sh frps                  start frps + web panel
#    ./start.sh --background          start web panel in background (nohup)
#    ./start.sh --stop                stop background panel / systemd service
#    ./start.sh --status              is the panel running?
#
#    # --- boot autostart (systemd; cron @reboot fallback) ---
#    sudo ./start.sh --install-service            install + enable panel autostart
#    sudo ./start.sh --install-service frps       install + enable frps autostart
#    sudo ./start.sh --install-service all        both
#    sudo ./start.sh --uninstall-service [panel|frps|all]
#    ./start.sh --service-status                  show unit status
#
#  Environment bootstrap is automatic: if python3 / venv / pip deps are
#  missing they are installed via the system package manager
#  (apt / dnf / yum / pacman / apk / zypper are supported).
# =============================================================================
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE"

VENV="$BASE/.venv"
PANEL_UNIT="cloudfrp-panel.service"
FRPS_UNIT="cloudfrp-frps.service"
SYSTEMD_DIR="/etc/systemd/system"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m OK\033[0m  %s\n' "$*"; }
warn(){ printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERR\033[0m  %s\n' "$*" >&2; }

SUDO=""
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# Package-manager abstraction: install system packages on any common distro
# ---------------------------------------------------------------------------
pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" \
      || { $SUDO apt-get update; $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; }
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --noconfirm --needed "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache "${pkgs[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y "${pkgs[@]}"
  else
    err "no supported package manager found; install manually: ${pkgs[*]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Environment bootstrap: python3 -> venv -> pip deps (all auto-installed)
# ---------------------------------------------------------------------------
bootstrap_env() {
  # 1) python3 interpreter
  PY=""
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && PY="$c" && break
  done
  if [[ -z "$PY" ]]; then
    log "python3 not found - installing via package manager"
    pkg_install python3 python3-pip || { err "could not install python3"; exit 1; }
    hash -r
    PY="python3"
  fi
  ok "$( $PY --version )"

  # 2) virtualenv (Debian/Ubuntu ship venv separately)
  if [[ ! -x "$VENV/bin/python" ]]; then
    log "creating virtualenv at $VENV"
    if ! $PY -m venv "$VENV" 2>/dev/null; then
      warn "venv module unavailable - installing python3-venv"
      if command -v apt-get >/dev/null 2>&1; then
        pkg_install python3-venv
      elif command -v apk >/dev/null 2>&1; then
        pkg_install python3-dev py3-pip
      else
        pkg_install python3-devel
      fi
      $PY -m venv "$VENV" || { err "venv creation failed"; exit 1; }
    fi
  fi
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  ok "virtualenv ready"

  # 3) python dependencies
  if [[ $EUID -eq 0 ]]; then export PIP_ROOT_USER_ACTION=ignore PIP_NO_CACHE_DIR=1; fi
  if ! python -c "import flask,pymysql,dotenv,bcrypt,psutil,dbutils,waitress" >/dev/null 2>&1; then
    log "installing dependencies (first run)"
    python -m pip install --quiet --upgrade pip
    python -m pip install --quiet Flask pymysql python-dotenv bcrypt psutil dbutils requests waitress \
      || { err "pip install failed"; exit 1; }
    ok "dependencies installed"
  else
    ok "dependencies present"
  fi
  if ! python -c "import waitress" >/dev/null 2>&1; then
    log "installing waitress (production WSGI server)"
    python -m pip install --quiet --no-cache-dir waitress || warn "waitress install failed, falling back to Flask dev server"
  fi
}

PYBIN="$VENV/bin/python"

# ---------------------------------------------------------------------------
# systemd autostart
# ---------------------------------------------------------------------------
have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

write_unit_panel() {
  cat > "$SYSTEMD_DIR/$PANEL_UNIT" <<UNIT
[Unit]
Description=CloudFRP Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$BASE/webpanel
ExecStart="$VENV/bin/python" -m waitress --listen=0.0.0.0:3592 --threads=8 --trusted-proxy=127.0.0.1 --trusted-proxy-headers=x-forwarded-proto server:app
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
}

write_unit_frps() {
  if [[ ! -x "$BASE/frps" ]]; then
    err "$BASE/frps not found - put the Linux frps binary there first"
    return 1
  fi
  cat > "$SYSTEMD_DIR/$FRPS_UNIT" <<UNIT
[Unit]
Description=CloudFRP frps server
After=network.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart="$BASE/frps" -c "$BASE/frps.toml"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

cron_line() {  # $1 = panel|frps -> @reboot fallback entry
  case "$1" in
    panel) echo "@reboot $VENV/bin/python $BASE/webpanel/server.py >> $BASE/panel.log 2>&1 # cloudfrp-panel" ;;
    frps)  echo "@reboot $BASE/frps -c $BASE/frps.toml >> $BASE/frps.log 2>&1 # cloudfrp-frps" ;;
  esac
}

install_service() {
  local target="${1:-panel}"
  [[ $EUID -eq 0 ]] || { err "service install needs root:  sudo ./start.sh --install-service $target"; exit 1; }
  bootstrap_env   # ensure venv exists before pointing systemd at it

  local unit
  for target in $([[ "$target" == "all" ]] && echo "panel frps" || echo "$target"); do
    if have_systemd; then
      case "$target" in
        panel) unit="$PANEL_UNIT"; write_unit_panel ;;
        frps)  unit="$FRPS_UNIT";  write_unit_frps ;;
      esac
      systemctl daemon-reload
      systemctl enable --now "$unit"
      ok "$target autostart installed AND started (systemctl enable --now $unit)"
    else
      warn "no systemd - using cron @reboot fallback"
      ( crontab -l 2>/dev/null | grep -v "# cloudfrp-$target$" ; cron_line "$target" ) | crontab -
      ok "$target autostart registered in crontab (starts on next boot)"
    fi
  done
}

uninstall_service() {
  local target="${1:-panel}"
  [[ $EUID -eq 0 ]] || { err "service uninstall needs root:  sudo ./start.sh --uninstall-service $target"; exit 1; }
  for target in $([[ "$target" == "all" ]] && echo "panel frps" || echo "$target"); do
    if have_systemd; then
      case "$target" in
        panel) unit="$PANEL_UNIT" ;;
        frps)  unit="$FRPS_UNIT" ;;
      esac
      systemctl disable --now "$unit" 2>/dev/null || true
      rm -f "$SYSTEMD_DIR/$unit"
      systemctl daemon-reload
      ok "$target autostart removed ($unit)"
    else
      ( crontab -l 2>/dev/null | grep -v "# cloudfrp-$target$" ) | crontab - || true
      ok "$target cron autostart removed"
    fi
  done
}

service_status() {
  if have_systemd; then
    for u in "$PANEL_UNIT" "$FRPS_UNIT"; do
      if [[ -f "$SYSTEMD_DIR/$u" ]]; then
        systemctl status "$u" --no-pager -l || true
      else
        warn "$u not installed"
      fi
    done
  else
    echo "--- crontab autostart entries ---"
    crontab -l 2>/dev/null | grep cloudfrp || warn "no cron autostart entries"
    echo "--- processes ---"
    pgrep -af "webpanel/server.py|frps" || warn "nothing running"
  fi
}

# ---------------------------------------------------------------------------
# Bootstrap the environment for every code path (cheap when already present)
# ---------------------------------------------------------------------------
bootstrap_env

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
case "${1:-}" in
  --stop)
    if have_systemd && [[ -f "$SYSTEMD_DIR/$PANEL_UNIT" ]]; then
      $SUDO systemctl stop "$PANEL_UNIT" && ok "systemd service stopped" || warn "systemctl stop failed"
    fi
    pkill -f "python .*webpanel/server.py" 2>/dev/null && ok "panel stopped" || warn "panel not running"
    exit 0 ;;
  --status)
    if pgrep -f "python .*webpanel/server.py" >/dev/null; then
      ok "panel running on http://localhost:3592"
    else
      err "panel not running"
    fi
    exit 0 ;;
  --install-service)  install_service "${2:-panel}"; exit 0 ;;
  --uninstall-service) uninstall_service "${2:-panel}"; exit 0 ;;
  --service-status)   service_status; exit 0 ;;
esac

# ---- optional frps (foreground runs) ----------------------------------------
if [[ "${1:-}" == "frps" ]]; then
  if [[ -x "$BASE/frps" ]]; then
    log "starting FRP server (frps)"
    ( cd "$BASE" && nohup ./frps -c frps.toml > "$BASE/frps.log" 2>&1 & )
    sleep 2
  else
    warn "frps binary not found, skipping"
  fi
fi

# ---- start panel -------------------------------------------------------------
echo
echo "  Panel:   http://localhost:3592"
echo "  Admin:   admin / yunwang"
echo "  Stop:    Ctrl+C  (or ./start.sh --stop)"
echo
cd "$BASE/webpanel"

RUN_CMD=("$PYBIN" "-m" "waitress" "--listen=0.0.0.0:3592" "--threads=8" "--trusted-proxy=127.0.0.1" "--trusted-proxy-headers=x-forwarded-proto" "server:app")
if ! $PYBIN -c "import waitress" >/dev/null 2>&1; then
  warn "waitress not installed, using Flask dev server"
  RUN_CMD=("$PYBIN" "server.py")
fi

if [[ "${1:-}" == "--background" ]]; then
  log "starting in background (log: $BASE/panel.log)"
  nohup "${RUN_CMD[@]}" > "$BASE/panel.log" 2>&1 &
  echo $! > "$BASE/panel.pid"
  ok "started pid $(cat "$BASE/panel.pid")"
else
  exec "${RUN_CMD[@]}"
fi
