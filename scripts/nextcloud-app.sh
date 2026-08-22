#!/usr/bin/env bash
# Start / stop / update Nextcloud AIO locally with data-safe upgrades and configurable backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${NEXTCLOUD_APP_CONFIG:-$ROOT/scripts/nextcloud-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"
OVERRIDE_FILE="$ROOT/docker-compose.override.yml"
MASTER="nextcloud-aio-mastercontainer"

# Defaults (overridden by config / env)
BACKUP_DIR="${BACKUP_DIR:-$ROOT/../nextcloud-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
AIO_PORT="${AIO_PORT:-8080}"
APACHE_PORT="${APACHE_PORT:-11000}"
NEXTCLOUD_DATADIR="${NEXTCLOUD_DATADIR:-$ROOT/../nextcloud-data}"
SKIP_DOMAIN_VALIDATION="${SKIP_DOMAIN_VALIDATION:-true}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-true}"

usage() {
  cat <<'EOF'
Usage: scripts/nextcloud-app.sh <command> [options]

Commands:
  start                 Start Nextcloud AIO in the background
  stop                  Stop containers (keeps all data)
  restart               stop then start (with readiness checks)
  down                  Remove the mastercontainer (keeps volumes; never uses -v)
  status                Show stack, ports, and backup status
  backup                Create a backup now
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Backup (if due) → optional git sync → pull & recreate (data kept)
  install-autostart     Install macOS LaunchAgent (start on login, keeps LAN proxy up)
  uninstall-autostart   Remove the LaunchAgent
  install-backup-schedule   Install monthly host backup (1st of month, 03:15)
  uninstall-backup-schedule Remove the monthly backup LaunchAgent
  schedule-hint         Print cron / launchd examples for monthly backups
  help                  Show this help

Update options:
  --sync / --no-sync    Force or skip git sync with upstream (default from config)
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/nextcloud-app.env.example → scripts/nextcloud-app.env
  Or set NEXTCLOUD_APP_CONFIG=/path/to/file
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$CONFIG_FILE"
    set +a
  fi

  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
  if [[ "$NEXTCLOUD_DATADIR" != /* ]]; then
    NEXTCLOUD_DATADIR="$ROOT/$NEXTCLOUD_DATADIR"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker is not running (start Docker Desktop)"
}

docker_sock() {
  if [[ -S /var/run/docker.sock ]]; then
    echo /var/run/docker.sock
  elif [[ -S /var/run/docker.sock.raw ]]; then
    echo /var/run/docker.sock.raw
  elif [[ -S "${HOME}/.docker/run/docker.sock" ]]; then
    echo "${HOME}/.docker/run/docker.sock"
  else
    echo /var/run/docker.sock
  fi
}

lan_ip() {
  ipconfig getifaddr en7 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true
}

ensure_runtime_files() {
  mkdir -p "$NEXTCLOUD_DATADIR"
  NEXTCLOUD_DATADIR="$(cd "$NEXTCLOUD_DATADIR" && pwd)"

  local sock
  sock="$(docker_sock)"

  if [[ ! -f "$OVERRIDE_FILE" ]]; then
    info "creating docker-compose.override.yml (localhost bind, skip domain check, host datadir)"
  fi

  # Always refresh so port/datadir/socket changes in nextcloud-app.env take effect.
  cat >"$OVERRIDE_FILE" <<EOF
# Local-only override (gitignored). Do not commit.
# Binds AIO UI to localhost; Nextcloud apache binds via APACHE_IP_BINDING.
# LAN access uses scripts/nextcloud-lan-proxy.py.
services:
  nextcloud-aio-mastercontainer:
    volumes: !override
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - ${sock}:/var/run/docker.sock:ro
    ports: !override
      - "127.0.0.1:${AIO_PORT}:8080"
    environment:
      SKIP_DOMAIN_VALIDATION: "${SKIP_DOMAIN_VALIDATION}"
      APACHE_PORT: "${APACHE_PORT}"
      APACHE_IP_BINDING: "127.0.0.1"
      WATCHTOWER_DOCKER_SOCKET_PATH: "/var/run/docker.sock"
      NEXTCLOUD_DATADIR: "${NEXTCLOUD_DATADIR}"
EOF
}

compose() {
  local args=(-f "./$COMPOSE_FILE")
  if [[ -f "$OVERRIDE_FILE" ]]; then
    args+=(-f "$OVERRIDE_FILE")
  fi
  docker compose "${args[@]}" "$@"
}

stack_running() {
  local ids
  ids="$(compose ps -q 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

master_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MASTER"
}

nextcloud_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nextcloud-aio-nextcloud'
}

database_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nextcloud-aio-database'
}

aio_initialized() {
  docker volume inspect nextcloud_aio_nextcloud >/dev/null 2>&1
}

wait_master() {
  local i
  for i in $(seq 1 60); do
    if master_running; then
      return 0
    fi
    sleep 2
  done
  warn "mastercontainer did not become running within 120s"
}

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}

wait_nextcloud() {
  local i st
  for i in $(seq 1 90); do
    st="$(container_health nextcloud-aio-nextcloud)"
    if [[ "$st" == "healthy" ]]; then
      # Entrypoint rewrites EuroOffice URLs; wait until it has finished.
      sleep 5
      return 0
    fi
    sleep 2
  done
  warn "nextcloud container did not become healthy within 180s"
}

wait_apache() {
  local i st
  for i in $(seq 1 60); do
    st="$(container_health nextcloud-aio-apache)"
    if [[ "$st" == "healthy" ]]; then
      return 0
    fi
    sleep 2
  done
  warn "apache container did not become healthy within 120s"
}

http_code() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000"
}

wait_http_ready() {
  local url="$1" i code
  for i in $(seq 1 45); do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^[23] ]]; then
      return 0
    fi
    sleep 2
  done
  warn "HTTP not ready at $url within 90s (last code: ${code:-000})"
  return 1
}

verify_connectivity() {
  local lip local_url lan_url local_code lan_code tries=0
  lip="$(lan_ip)"
  local_url="http://127.0.0.1:${APACHE_PORT}/"
  lan_url=""
  [[ -n "$lip" ]] && lan_url="http://${lip}:${APACHE_PORT}/"

  while [[ "$tries" -lt 3 ]]; do
    local_code="$(http_code "$local_url")"
    if [[ -n "$lan_url" ]]; then
      lan_code="$(http_code "$lan_url")"
    else
      lan_code="skip"
    fi

    if [[ "$local_code" =~ ^[23] ]] && { [[ "$lan_code" == "skip" ]] || [[ "$lan_code" =~ ^[23] ]]; }; then
      if [[ "$lan_code" == "skip" ]]; then
        info "connectivity OK (localhost=${local_code})"
      else
        info "connectivity OK (localhost=${local_code}, LAN=${lan_code})"
      fi
      return 0
    fi

    tries=$((tries + 1))
    warn "connectivity check failed (localhost=${local_code:-000}, LAN=${lan_code:-000}); restarting LAN proxy (attempt ${tries}/3)"
    start_lan_proxy
    sleep 2
  done

  warn "could not verify HTTP access - try: $0 restart"
  warn "if LAN fails but localhost works, allow incoming connections for Python in System Settings > Network > Firewall"
  return 1
}

LAN_PROXY="$ROOT/scripts/nextcloud-lan-proxy.py"
LAN_PROXY_PID="$ROOT/scripts/.nextcloud-lan-proxy.pid"

stop_lan_proxy() {
  if [[ -f "$LAN_PROXY_PID" ]]; then
    local pid
    pid="$(cat "$LAN_PROXY_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "stopping LAN proxy (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$LAN_PROXY_PID"
  fi
  pkill -f 'nextcloud-lan-proxy.py' 2>/dev/null || true
}

start_lan_proxy() {
  stop_lan_proxy
  [[ -f "$LAN_PROXY" ]] || die "missing $LAN_PROXY"
  info "starting LAN proxy (phone → LAN:${APACHE_PORT}, AIO UI → LAN:${AIO_PORT})"
  python3 "$LAN_PROXY" \
    --map "${APACHE_PORT}:${APACHE_PORT}" \
    --map "${AIO_PORT}:${AIO_PORT}" \
    --daemon \
    --pid-file "$LAN_PROXY_PID"
  sleep 0.5
}

print_urls() {
  local lip
  lip="$(lan_ip)"
  info "AIO interface (this Mac): https://127.0.0.1:${AIO_PORT}  (self-signed cert; use the IP, not a hostname)"
  info "Nextcloud (after first AIO setup): http://127.0.0.1:${APACHE_PORT}"
  if [[ -n "$lip" ]]; then
    info "phone Server URL: http://${lip}:${APACHE_PORT}"
    info "phone AIO UI:     https://${lip}:${AIO_PORT}"
  else
    info "phone Server URL: http://<your-mac-lan-ip>:${APACHE_PORT}"
  fi
}

trust_lan_domain() {
  nextcloud_running || return 0
  local lip
  lip="$(lan_ip)"
  [[ -n "$lip" ]] || return 0
  info "adding LAN IP to Nextcloud trusted_domains ($lip)"
  docker exec nextcloud-aio-nextcloud php occ config:system:set trusted_domains 10 --value="$lip" >/dev/null 2>&1 || true
  docker exec nextcloud-aio-nextcloud php occ config:system:set trusted_domains 11 --value="${lip}:${APACHE_PORT}" >/dev/null 2>&1 || true
}

# AIO defaults EuroOffice to https://nextcloud.local; this local stack is HTTP on the LAN IP.
fix_local_office() {
  nextcloud_running || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nextcloud-aio-eurooffice' || return 0
  local lip
  lip="$(lan_ip)"
  [[ -n "$lip" ]] || return 0
  info "pointing Nextcloud Office (EuroOffice) at http://${lip}:${APACHE_PORT}/eurooffice"
  docker exec nextcloud-aio-nextcloud php occ config:app:set eurooffice DocumentServerUrl --value="http://${lip}:${APACHE_PORT}/eurooffice" >/dev/null 2>&1 || true
  docker exec nextcloud-aio-nextcloud php occ config:app:set eurooffice DocumentServerInternalUrl --value='http://nextcloud-aio-eurooffice/' >/dev/null 2>&1 || true
  docker exec nextcloud-aio-nextcloud php occ config:app:set eurooffice StorageUrl --value="http://${lip}:${APACHE_PORT}/" >/dev/null 2>&1 || true
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nextcloud-aio-apache'; then
    docker exec nextcloud-aio-apache sh -c "sed -i 's/header_up X-Forwarded-Proto https/header_up X-Forwarded-Proto http/g' /tmp/Caddyfile" 2>/dev/null || true
    docker exec nextcloud-aio-apache sh -c 'kill -USR1 "$(pgrep -x caddy)" 2>/dev/null || true' || true
  fi
}

cmd_start() {
  require_docker
  ensure_runtime_files
  info "pulling images (if needed) and starting Nextcloud AIO mastercontainer"
  compose pull
  compose up -d --remove-orphans
  wait_master

  if aio_initialized && master_running; then
    info "existing AIO instance detected — starting Nextcloud containers"
    docker exec --env START_CONTAINERS=1 "$MASTER" /daily-backup.sh || warn "START_CONTAINERS returned non-zero (AIO may still be booting)"
    wait_apache
    wait_nextcloud
    trust_lan_domain
    fix_local_office
  else
    info "first run: open the AIO interface, accept the self-signed cert, save the passphrase,"
    info "then enter a domain (skip validation is on) and click Start containers."
    info "Use skip_domain_validation if prompted: https://127.0.0.1:${AIO_PORT}/containers?skip_domain_validation"
  fi

  # Start LAN proxy only after apache is listening (daily-backup.sh restarts containers).
  wait_http_ready "http://127.0.0.1:${APACHE_PORT}/" || true
  start_lan_proxy
  verify_connectivity || true

  print_urls
  compose ps
}

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start
}

cmd_stop() {
  require_docker
  ensure_runtime_files
  stop_lan_proxy
  if master_running && aio_initialized; then
    info "stopping Nextcloud sibling containers (data retained)"
    docker exec --env STOP_CONTAINERS=1 "$MASTER" /daily-backup.sh || true
  fi
  info "stopping AIO mastercontainer (data retained)"
  compose stop
}

cmd_down() {
  require_docker
  ensure_runtime_files
  stop_lan_proxy
  if master_running && aio_initialized; then
    info "stopping Nextcloud sibling containers (volumes retained)"
    docker exec --env STOP_CONTAINERS=1 "$MASTER" /daily-backup.sh || true
  fi
  info "removing AIO mastercontainer (no -v; volumes and datadir retained)"
  compose down --remove-orphans
}

cmd_status() {
  require_docker
  ensure_runtime_files
  local lip
  lip="$(lan_ip)"

  echo "config:     $CONFIG_FILE$([ -f "$CONFIG_FILE" ] && echo '' || echo ' (missing — using defaults)')"
  echo "compose:    $COMPOSE_FILE"
  echo "override:   $OVERRIDE_FILE$([ -f "$OVERRIDE_FILE" ] && echo '' || echo ' (will be created on start)')"
  echo "AIO UI:     https://127.0.0.1:${AIO_PORT}"
  echo "Nextcloud:  http://127.0.0.1:${APACHE_PORT}"
  if [[ -n "$lip" ]]; then
    echo "phone URL:  http://${lip}:${APACHE_PORT}"
  fi
  echo "datadir:    $NEXTCLOUD_DATADIR"
  echo "docker sock:$(docker_sock)"
  echo "backups:    $BACKUP_DIR"
  echo "interval:   every $BACKUP_INTERVAL_DAYS day(s), keep $BACKUP_KEEP"
  echo

  local latest age local_code lan_code
  if stack_running; then
    compose ps
  else
    echo "mastercontainer: not running"
  fi
  echo
  echo "AIO containers:"
  docker ps --filter 'name=nextcloud-aio-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "(none)"
  echo
  if nextcloud_running; then
    local_code="$(http_code "http://127.0.0.1:${APACHE_PORT}/")"
    echo "HTTP localhost: ${local_code}"
    if [[ -n "$lip" ]]; then
      lan_code="$(http_code "http://${lip}:${APACHE_PORT}/")"
      echo "HTTP LAN (${lip}): ${lan_code}"
    fi
    if [[ -f "$LAN_PROXY_PID" ]]; then
      echo "LAN proxy pid: $(cat "$LAN_PROXY_PID" 2>/dev/null || echo unknown)"
    else
      echo "LAN proxy: not running (run start to enable phone/LAN access)"
    fi
  fi
  echo

  if latest="$(last_backup_dir)"; then
    age="$(backup_age_days || echo '?')"
    echo "last backup: $latest (${age} day(s) ago)"
  else
    echo "last backup: none"
  fi
}

last_backup_dir() {
  [[ -d "$BACKUP_DIR" ]] || return 1
  local latest
  latest="$(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | head -n1 || true)"
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

backup_age_days() {
  local latest mtime now
  latest="$(last_backup_dir)" || return 1
  if [[ -f "$latest/.nextcloud-backup-complete" ]]; then
    mtime="$(stat -f %m "$latest/.nextcloud-backup-complete" 2>/dev/null || stat -c %Y "$latest/.nextcloud-backup-complete")"
  else
    mtime="$(stat -f %m "$latest" 2>/dev/null || stat -c %Y "$latest")"
  fi
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

prune_backups() {
  local keep="${BACKUP_KEEP:-3}"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$BACKUP_DIR" ]] || return 0
  local i=0 dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    i=$((i + 1))
    if [[ "$i" -gt "$keep" ]]; then
      info "pruning old backup: $dir"
      rm -rf "$dir"
    fi
  done < <(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null || true)
}

copy_volume() {
  local vname="$1" dest="$2"
  if docker volume inspect "$vname" >/dev/null 2>&1; then
    docker run --rm \
      -v "${vname}:/from:ro" \
      -v "$dest:/to" \
      docker.io/library/alpine:3.20 \
      sh -c "mkdir -p /to/$vname && cp -a /from/. /to/$vname/"
  else
    warn "volume missing: $vname"
  fi
}

do_backup() {
  local if_due=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --if-due) if_due=true ;;
      *) die "unknown backup option: $1" ;;
    esac
    shift
  done

  ensure_runtime_files

  if [[ "$if_due" == true ]]; then
    local age
    if age="$(backup_age_days 2>/dev/null)"; then
      if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
        info "backup not due (last was ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
        return 0
      fi
    fi
  fi

  require_docker
  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  info "backing up to $dest"

  if database_running; then
    info "dumping database (pg_dumpall as nextcloud)"
    docker exec nextcloud-aio-database pg_dumpall -U nextcloud \
      >"$dest/nextcloud.sql" || warn "pg_dumpall failed"
  else
    warn "database container not running — skipping SQL dump; copying volumes instead"
  fi

  if [[ -d "$NEXTCLOUD_DATADIR" ]]; then
    info "copying Nextcloud datadir"
    mkdir -p "$dest/ncdata"
    rsync -a "$NEXTCLOUD_DATADIR/" "$dest/ncdata/" 2>/dev/null || cp -a "$NEXTCLOUD_DATADIR/." "$dest/ncdata/"
  fi

  info "copying Docker volumes (mastercontainer + core AIO volumes)"
  mkdir -p "$dest/volumes"
  local vol
  for vol in nextcloud_aio_mastercontainer nextcloud_aio_nextcloud nextcloud_aio_database \
             nextcloud_aio_database_dump nextcloud_aio_apache nextcloud_aio_redis; do
    copy_volume "$vol" "$dest/volumes"
  done

  if [[ -f "$OVERRIDE_FILE" ]]; then
    cp "$OVERRIDE_FILE" "$dest/docker-compose.override.yml"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$dest/nextcloud-app.env"
  fi

  cat >"$dest/MANIFEST.txt" <<EOF
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$(hostname)
git_head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
compose_file=$COMPOSE_FILE
aio_port=$AIO_PORT
apache_port=$APACHE_PORT
datadir=$NEXTCLOUD_DATADIR
EOF
  touch "$dest/.nextcloud-backup-complete"

  prune_backups
  info "backup complete: $dest"
}

cmd_update() {
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup="if-due"
  local rebase=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=force ;;
      --no-backup) do_backup=skip ;;
      --rebase) rebase=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  require_docker
  ensure_runtime_files

  case "$do_backup" in
    force) do_backup ;;
    if-due) do_backup --if-due ;;
    skip) info "skipping backup (--no-backup)" ;;
  esac

  if [[ "$do_sync" == true || "$do_sync" == "true" ]]; then
    [[ -x "$SYNC_SCRIPT" ]] || die "missing $SYNC_SCRIPT"
    info "syncing from Nextcloud AIO upstream"
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  else
    info "skipping git sync"
  fi

  info "pulling images and recreating mastercontainer (volumes / datadir kept)"
  # Intentionally no -v / --renew-anon-volumes: protect named volumes and NEXTCLOUD_DATADIR.
  compose pull
  compose up -d --remove-orphans --force-recreate
  wait_master

  if aio_initialized && master_running; then
    info "updating and starting Nextcloud sibling containers via AIO"
    docker exec --env AUTOMATIC_UPDATES=1 "$MASTER" /daily-backup.sh || warn "AUTOMATIC_UPDATES returned non-zero"
  fi

  wait_apache
  wait_nextcloud
  wait_http_ready "http://127.0.0.1:${APACHE_PORT}/" || true
  start_lan_proxy

  if aio_initialized && master_running; then
    trust_lan_domain
    fix_local_office
  fi

  verify_connectivity || true

  info "update complete"
  print_urls
  compose ps
}

cmd_schedule_hint() {
  local script="$ROOT/scripts/nextcloud-app.sh"
  cat <<EOF
# Cron (monthly check on the 1st at 03:15) — uses BACKUP_INTERVAL_DAYS via --if-due
15 3 1 * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# Cron (daily check; only backs up when due)
15 3 * * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# macOS launchd (save as ~/Library/LaunchAgents/com.nextcloud.host-backup.plist)
# ProgramArguments: $script
#               backup
#               --if-due
# StartCalendarInterval: Day=1 Hour=3 Minute=15

# Always-on (login): scripts/nextcloud-app.sh install-autostart
# Monthly backup:   scripts/nextcloud-app.sh install-backup-schedule

Config file: $CONFIG_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_INTERVAL_DAYS=$BACKUP_INTERVAL_DAYS
EOF
}

BACKUP_SCHEDULE_LABEL="com.nextcloud.host-backup"
BACKUP_SCHEDULE_PLIST="${HOME}/Library/LaunchAgents/${BACKUP_SCHEDULE_LABEL}.plist"

cmd_install_backup_schedule() {
  local script="$ROOT/scripts/nextcloud-app.sh"
  mkdir -p "$BACKUP_DIR"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat >"$BACKUP_SCHEDULE_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nextcloud.host-backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>__BACKUP_CMD__</string>
  </array>
  <key>WorkingDirectory</key>
  <string>__ROOT__</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Day</key>
    <integer>1</integer>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>15</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>__LOG_PATH__</string>
  <key>StandardErrorPath</key>
  <string>__LOG_PATH__</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
PLIST
  local backup_cmd log_path backup_cmd_esc log_path_esc root_esc
  backup_cmd="for i in \$(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 5; done; exec ${script} backup --if-due"
  log_path="${BACKUP_DIR}/backup.log"
  backup_cmd_esc="$(escape_sed_replacement "$backup_cmd")"
  log_path_esc="$(escape_sed_replacement "$log_path")"
  root_esc="$(escape_sed_replacement "$ROOT")"
  # shellcheck disable=SC2016
  sed -i '' \
    -e "s|__BACKUP_CMD__|${backup_cmd_esc}|" \
    -e "s|__ROOT__|${root_esc}|" \
    -e "s|__LOG_PATH__|${log_path_esc}|" \
    "$BACKUP_SCHEDULE_PLIST"
  launchctl bootout "gui/$(id -u)/${BACKUP_SCHEDULE_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$BACKUP_SCHEDULE_PLIST"
  info "installed monthly backup LaunchAgent: $BACKUP_SCHEDULE_PLIST"
  info "runs on the 1st of each month at 03:15 (backup --if-due, interval ${BACKUP_INTERVAL_DAYS} days)"
  info "log: ${log_path}"
  info "remove with: $0 uninstall-backup-schedule"
}

cmd_uninstall_backup_schedule() {
  launchctl bootout "gui/$(id -u)/${BACKUP_SCHEDULE_LABEL}" 2>/dev/null || true
  rm -f "$BACKUP_SCHEDULE_PLIST"
  info "removed LaunchAgent ${BACKUP_SCHEDULE_LABEL}"
}

escape_sed_replacement() {
  # Escape &, \, and | for use in sed replacement with | delimiter.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//|/\\|}"
  s="${s//&/\\&}"
  printf '%s' "$s"
}

AUTOSTART_LABEL="com.nextcloud.aio.autostart"
AUTOSTART_PLIST="${HOME}/Library/LaunchAgents/${AUTOSTART_LABEL}.plist"

cmd_install_autostart() {
  local script="$ROOT/scripts/nextcloud-app.sh"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat >"$AUTOSTART_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nextcloud.aio.autostart</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>__START_CMD__</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>__LOG_PATH__</string>
  <key>StandardErrorPath</key>
  <string>__LOG_PATH__</string>
</dict>
</plist>
PLIST
  local start_cmd log_path start_cmd_esc log_path_esc
  start_cmd="for i in \$(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 5; done; exec ${script} start"
  log_path="${ROOT}/scripts/.nextcloud-autostart.log"
  start_cmd_esc="$(escape_sed_replacement "$start_cmd")"
  log_path_esc="$(escape_sed_replacement "$log_path")"
  # shellcheck disable=SC2016
  sed -i '' \
    -e "s|__START_CMD__|${start_cmd_esc}|" \
    -e "s|__LOG_PATH__|${log_path_esc}|" \
    "$AUTOSTART_PLIST"
  launchctl bootout "gui/$(id -u)/${AUTOSTART_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AUTOSTART_PLIST"
  info "installed LaunchAgent: $AUTOSTART_PLIST"
  info "Nextcloud will start automatically when you log in (waits up to 5 min for Docker Desktop)."
  info "Remove with: $0 uninstall-autostart"
}

cmd_uninstall_autostart() {
  launchctl bootout "gui/$(id -u)/${AUTOSTART_LABEL}" 2>/dev/null || true
  rm -f "$AUTOSTART_PLIST"
  info "removed LaunchAgent ${AUTOSTART_LABEL}"
}

main() {
  load_config
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    -h|--help|help) usage ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    down) cmd_down ;;
    status) cmd_status ;;
    backup) do_backup "$@" ;;
    update) cmd_update "$@" ;;
    install-autostart) cmd_install_autostart ;;
    uninstall-autostart) cmd_uninstall_autostart ;;
    install-backup-schedule) cmd_install_backup_schedule ;;
    uninstall-backup-schedule) cmd_uninstall_backup_schedule ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd (try help)" ;;
  esac
}

main "$@"
