#!/usr/bin/env bash
# =============================================================================
#  CloudFRP Panel - one-click deploy + start (Linux / WSL)
#
#  Fresh server:   sudo ./deploy.sh
#  Custom path:    sudo ./deploy.sh --dir /opt/cloudfrp
#  Apply update:   sudo ./deploy.sh --update --from-zip cloudfrp-update-20261122.zip
#  No systemd:     sudo ./deploy.sh --no-service
#  Uninstall:      sudo ./deploy.sh --uninstall
#
#  What it does, in order:
#    1. installs python3 / venv / pip / curl / unzip when missing
#    2. copies the project to --dir (default: where this script lives)
#    3. creates .venv and installs requirements (PyPI mirror fallback)
#    4. generates .env with SECRET_KEY / DEFAULT_AUTH_TOKEN if absent
#    5. runs idempotent DB migrations
#    6. creates the first admin (random password, printed once) if DB is empty
#    7. installs + enables cloudfrp-panel.service (or nohup with --no-service)
#    8. waits for GET /api/health and prints the access URL
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- defaults ---
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SRC"
PORT="3592"
HOST="0.0.0.0"
ADMIN_PW=""
NO_SERVICE=0
UNINSTALL=0
PURGE=0
UPDATE=0
FROM_ZIP=""
UNIT_NAME="cloudfrp-panel.service"
SYSTEMD_DIR="/etc/systemd/system"

# ---------------------------------------------------------------- logging ----
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR\033[0m  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
CloudFRP one-click deploy

  sudo ./deploy.sh [options]

Options:
  --dir PATH          install/copy into PATH (default: this script's folder)
  --port N            panel port (default 3592)
  --host ADDR         listen address (default 0.0.0.0)
  --password PW       password for the first admin (default: random)
  --update            update mode: keep .env and database, skip admin creation
  --from-zip FILE     unzip an update package into the target before deploying
  --no-service        do not install systemd; start with nohup instead
  --uninstall         stop + disable + remove the systemd unit (data kept)
  --purge             with --uninstall: also delete the whole target folder
  -h, --help          this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      TARGET="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --password) ADMIN_PW="$2"; shift 2 ;;
    --update)   UPDATE=1; shift ;;
    --from-zip) FROM_ZIP="$2"; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)    PURGE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "invalid --port: $PORT"

# ---------------------------------------------------------------- sudo -------
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "run as root (no sudo available)"
  fi
fi

# ---------------------------------------------------------------- packages ---
pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --noconfirm --needed "${pkgs[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache "${pkgs[@]}"
  else
    warn "no supported package manager; install manually: ${pkgs[*]}"
    return 0
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- uninstall --
if (( UNINSTALL )); then
  log "uninstalling $UNIT_NAME"
  if need_cmd systemctl; then
    $SUDO systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  $SUDO rm -f "$SYSTEMD_DIR/$UNIT_NAME"
  need_cmd systemctl && $SUDO systemctl daemon-reload || true
  if [[ -f "$TARGET/cloudfrp.pid" ]]; then
    kill "$(cat "$TARGET/cloudfrp.pid")" >/dev/null 2>&1 || true
    rm -f "$TARGET/cloudfrp.pid"
  fi
  ok "service removed; data kept in $TARGET"
  if (( PURGE )); then
    log "purging $TARGET"
    $SUDO rm -rf "$TARGET"
    ok "target deleted"
  fi
  exit 0
fi

# ---------------------------------------------------------------- copy -------
log "source: $SRC"
log "target: $TARGET"
if [[ "$TARGET" != "$SRC" ]]; then
  $SUDO mkdir -p "$TARGET"
  if need_cmd rsync; then
    $SUDO rsync -a \
      --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' \
      --exclude '_trash' --exclude '_shots' --exclude '*.db' \
      --exclude '*.db-wal' --exclude '*.db-shm' --exclude '.env' \
      "$SRC"/ "$TARGET"/
  else
    $SUDO cp -a "$SRC"/. "$TARGET"/
    $SUDO rm -rf "$TARGET/.venv" "$TARGET/_trash" "$TARGET/_shots"
  fi
fi

# update package (optional)
if [[ -n "$FROM_ZIP" ]]; then
  [[ -f "$FROM_ZIP" ]] || die "zip not found: $FROM_ZIP"
  need_cmd unzip || pkg_install unzip
  log "applying update package: $FROM_ZIP"
  $SUDO unzip -o -q "$FROM_ZIP" -d "$TARGET"
  ok "update files extracted"
fi

# resolve the panel directory (supports both layouts)
if [[ -f "$TARGET/webpanel/server.py" ]]; then
  APP="$TARGET/webpanel"
elif [[ -f "$TARGET/server.py" ]]; then
  APP="$TARGET"
else
  die "server.py not found under $TARGET (expected $TARGET/webpanel/server.py)"
fi
log "panel dir: $APP"

# ---------------------------------------------------------------- python -----
PY=""
for c in python3 python; do
  if need_cmd "$c" && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
if [[ -z "$PY" ]]; then
  log "python3 not found - installing"
  pkg_install python3 python3-venv python3-pip
  hash -r
  PY="$(command -v python3 || command -v python)"
fi
[[ -n "$PY" ]] || die "python3 is required"
ok "$($PY --version 2>&1)"

need_cmd curl || pkg_install curl

# venv support (Debian/Ubuntu split package)
if ! "$PY" -c 'import venv' >/dev/null 2>&1; then
  pkg_install python3-venv
fi

VENV="$TARGET/.venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  log "creating virtualenv: $VENV"
  $SUDO "$PY" -m venv "$VENV"
fi
VPY="$VENV/bin/python"
$SUDO "$VPY" -m pip install --upgrade pip wheel >/dev/null 2>&1 || true

log "installing Python dependencies"
if ! $SUDO "$VPY" -m pip install -q -r "$APP/requirements.txt"; then
  warn "PyPI install failed; retrying with Tsinghua mirror"
  $SUDO "$VPY" -m pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple -r "$APP/requirements.txt" \
    || die "dependency installation failed"
fi
ok "dependencies installed"

# ---------------------------------------------------------------- .env -------
ENV_FILE="$APP/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "creating $ENV_FILE"
  SECRET_KEY="$($VPY -c 'import secrets; print(secrets.token_hex(32))')"
  AUTH_TOKEN="$($VPY -c 'import secrets; print(secrets.token_hex(16))')"
  $SUDO tee "$ENV_FILE" >/dev/null <<EOF
# CloudFRP panel environment (generated by deploy.sh)
SECRET_KEY=$SECRET_KEY
DEFAULT_AUTH_TOKEN=$AUTH_TOKEN

PANEL_HOST=$HOST
PANEL_PORT=$PORT
CLOUDFRP_VERSION=1.1.0

# SQLite by default; set USE_MYSQL=true and fill the block to use MySQL
USE_MYSQL=false
DB_HOST=localhost
DB_PORT=3306
DB_USER=root
DB_PASSWORD=
DB_NAME=frp_panel

# Mail (needed for high-risk operation verification codes)
SMTP_HOST=smtp.qq.com
SMTP_PORT=465
SMTP_SSL=true
SMTP_USER=
SMTP_PASS=
SMTP_FROM=
EOF
  $SUDO chmod 600 "$ENV_FILE"
  ok ".env created (fill SMTP_USER / SMTP_PASS / SMTP_FROM to enable email codes)"
else
  log ".env exists - keeping it"
  # keep the configured port in sync with --port
  if grep -q '^PANEL_PORT=' "$ENV_FILE"; then
    $SUDO sed -i "s/^PANEL_PORT=.*/PANEL_PORT=$PORT/" "$ENV_FILE"
  else
    echo "PANEL_PORT=$PORT" | $SUDO tee -a "$ENV_FILE" >/dev/null
  fi
  grep -q '^SECRET_KEY=' "$ENV_FILE" || {
    $SUDO bash -c "echo SECRET_KEY=\$($VPY -c 'import secrets;print(secrets.token_hex(32))') >> '$ENV_FILE'"
  }
fi

# ---------------------------------------------------------------- database ---
log "running database migrations"
( cd "$APP" && $SUDO "$VPY" -c "from app.database import db; db.init_tables(); print('migrations OK')" )
ok "database ready"

# ---------------------------------------------------------------- admin ------
CREATE_ADMIN=0
if (( ! UPDATE )); then
  RESULT="$( cd "$APP" && $SUDO env CF_ADMIN_PW="$ADMIN_PW" "$VPY" - <<'PY'
import os
from app.database import db
from app.services.user_service import user_service

row = db.fetchone("SELECT COUNT(*) AS c FROM users")
if row and row["c"]:
    print("SKIP")
    raise SystemExit(0)

pw = (os.environ.get("CF_ADMIN_PW") or "").strip()
generated = False
if len(pw) < 6:
    import secrets as _s, string as _st
    pw = "".join(_s.choice(_st.ascii_letters + _st.digits) for _ in range(16))
    generated = True

ok, msg = user_service.register("admin", pw, "admin@localhost")
if not ok:
    print("FAIL:" + msg)
    raise SystemExit(0)
db.execute("UPDATE users SET role = 'admin' WHERE username = 'admin'")
print("CREATED:" + pw + (":generated" if generated else ""))
PY
)" 2>/dev/null || RESULT="FAIL:python error"
  case "$RESULT" in
    CREATED:*) CREATE_ADMIN=1; ADMIN_PW="${RESULT#CREATED:}"; ADMIN_PW="${ADMIN_PW%:generated}" ;;
    SKIP)      log "admin already exists - not touching accounts" ;;
    FAIL:*)    warn "admin bootstrap failed: ${RESULT#FAIL:}" ;;
    *)         warn "admin bootstrap returned: $RESULT" ;;
  esac
fi

# ---------------------------------------------------------------- service ----
start_nohup() {
  local logfile="$TARGET/cloudfrp.log"
  log "starting panel with nohup (log: $logfile)"
  local pid
  pid="$($SUDO bash -c "cd '$APP' && PANEL_HOST='$HOST' PANEL_PORT='$PORT' nohup '$VPY' -m waitress --listen='$HOST:$PORT' --threads=8 server:app >'$logfile' 2>&1 & echo \$!")"
  echo "$pid" | $SUDO tee "$TARGET/cloudfrp.pid" >/dev/null
}

if (( NO_SERVICE )) || ! need_cmd systemctl; then
  (( NO_SERVICE )) || warn "systemd not available - falling back to nohup"
  # stop an old nohup instance if present
  if [[ -f "$TARGET/cloudfrp.pid" ]]; then
    kill "$(cat "$TARGET/cloudfrp.pid")" >/dev/null 2>&1 || true
    sleep 1
  fi
  start_nohup
else
  log "installing $UNIT_NAME"
  $SUDO tee "$SYSTEMD_DIR/$UNIT_NAME" >/dev/null <<EOF
[Unit]
Description=CloudFRP Panel (Flask + waitress)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP
EnvironmentFile=$ENV_FILE
ExecStart=$VPY -m waitress --listen=$HOST:$PORT --threads=8 --trusted-proxy=127.0.0.1 --trusted-proxy-headers=x-forwarded-proto server:app
Restart=always
RestartSec=5
TimeoutStopSec=15
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
  $SUDO systemctl restart "$UNIT_NAME"
  ok "service enabled (starts on boot)"
fi

# ---------------------------------------------------------------- firewall ---
if need_cmd ufw && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  $SUDO ufw allow "$PORT/tcp" >/dev/null 2>&1 && log "ufw: allowed $PORT/tcp" || true
elif need_cmd firewall-cmd && $SUDO firewall-cmd --state >/dev/null 2>&1; then
  $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 \
    && $SUDO firewall-cmd --reload >/dev/null 2>&1 \
    && log "firewalld: allowed $PORT/tcp" || true
fi

# ---------------------------------------------------------------- health -----
log "waiting for panel to answer"
HEALTH="http://127.0.0.1:$PORT/api/health"
HEALTHY=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 1
done

echo
if (( HEALTHY )); then
  ok "panel is up"
  curl -fsS --max-time 3 "$HEALTH" 2>/dev/null || true
  echo
else
  warn "panel did not answer /api/health within 30s"
  if (( NO_SERVICE )); then
    echo "  log: $TARGET/cloudfrp.log"
  else
    echo "  log: journalctl -u $UNIT_NAME -n 80 --no-pager"
  fi
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo
echo "============================================================"
echo " CloudFRP panel"
echo "   URL      : http://${IP:-<server-ip>}:$PORT/"
echo "   health   : http://${IP:-<server-ip>}:$PORT/api/health"
echo "   install  : $TARGET"
if (( CREATE_ADMIN )); then
  echo "   admin    : admin / $ADMIN_PW"
  echo "              (save this password now; it is not stored in plaintext)"
fi
if (( NO_SERVICE )) || ! need_cmd systemctl; then
  echo "   start    : $TARGET/deploy.sh --no-service"
  echo "   stop     : kill \$(cat $TARGET/cloudfrp.pid)"
else
  echo "   status   : systemctl status $UNIT_NAME"
  echo "   restart  : systemctl restart $UNIT_NAME"
  echo "   logs     : journalctl -u $UNIT_NAME -f"
fi
echo "   remind   : open TCP $PORT in the firewall / security group"
echo "============================================================"
