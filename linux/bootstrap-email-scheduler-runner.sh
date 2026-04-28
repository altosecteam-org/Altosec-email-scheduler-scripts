#!/usr/bin/env bash
# Altosec Email Scheduler — Linux / WSL2 runner bootstrap.
#
# Works on bare-metal Ubuntu/Debian AND inside WSL2 Ubuntu.
# Idempotent: each step checks whether the component is already present and
# skips installation if so. Safe to run again after partial failure.
#
# What this script does:
#   1. Install Docker Engine (skipped if already present)
#   2. Set system environment variables in /etc/environment (idempotent)
#   3. Open firewall ports via ufw (idempotent)
#   4. Download and configure a GitHub Actions self-hosted runner (skipped if .runner exists)
#   5. Install and start the runner as a systemd service (or init.d fallback)
#
# Requirements:
#   - Ubuntu 20.04+ or Debian 11+ (bare-metal or WSL2)
#   - Run as root: sudo bash bootstrap-email-scheduler-runner.sh [options]
#   - Internet access for Docker / runner downloads
#
# On Windows: run this script INSIDE WSL2 Ubuntu. Configure WSL2 mirrored
# networking first (scripts/windows/setup-wsl2-docker.ps1) so that
# network_mode: host in Docker sees real client IPs.
#
# Usage:
#   sudo bash bootstrap-email-scheduler-runner.sh [--tls] [--http-only]
#   ALTOSEC_BOOTSTRAP_TLS=1 sudo bash bootstrap-email-scheduler-runner.sh
#
# Parameters (all can be passed as env vars):
#   --tls             Enable TLS / Let's Encrypt path (prompts for FQDN)
#   --http-only       HTTP-only mode (default; no domain or ACME)
#   RUNNER_NAME       Runner name (unique on GitHub)
#   REGISTRATION_TOKEN  GitHub registration token
#   DEPLOY_DOMAIN_FQDN  Public FQDN (--tls only)
#   ACME_CONTACT_EMAIL  Let's Encrypt contact email
#   RUNNER_ROOT       Runner install path (default /opt/actions-runner-email-scheduler)
#   ALTOSEC_EMAIL_DEPLOY_DIR  Deploy directory (default /opt/altosec-deploy-email)
#   REPO_URL          GitHub repo URL (default https://github.com/alto-sec/Altosec-email-scheduler)

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"
}

is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null
}

# ── parse flags ───────────────────────────────────────────────────────────────
USE_TLS=false
for arg in "$@"; do
  case "$arg" in
    --tls)       USE_TLS=true ;;
    --http-only) USE_TLS=false ;;
  esac
done
[[ "${ALTOSEC_BOOTSTRAP_TLS:-}"       =~ ^(1|true|yes|on)$  ]] && USE_TLS=true
[[ "${ALTOSEC_BOOTSTRAP_HTTP_ONLY:-}" =~ ^(1|true|yes|on)$  ]] && USE_TLS=false

require_root

# ── defaults ──────────────────────────────────────────────────────────────────
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner-email-scheduler}"
DEPLOY_DIR="${ALTOSEC_EMAIL_DEPLOY_DIR:-/opt/altosec-deploy-email}"
REPO_URL="${REPO_URL:-https://github.com/alto-sec/Altosec-email-scheduler}"
RUNNER_SVC_USER="root"

# ── interactive prompts ───────────────────────────────────────────────────────
# Always read from /dev/tty so prompts work even when stdin is a pipe
# (e.g. curl ... | sudo bash).
read_val() {
  local var="$1" prompt="$2" default="${3:-}" val
  if [[ -n "${!var:-}" ]]; then return; fi
  local hint=""; [[ -n "$default" ]] && hint=" [$default]"
  read -rp "$prompt$hint: " val </dev/tty
  printf -v "$var" '%s' "${val:-$default}"
}

if $USE_TLS; then
  read_val DEPLOY_DOMAIN_FQDN "Public FQDN for email TLS (ALTOSEC_EMAIL_DEPLOY_DOMAIN)" ""
  read_val ACME_CONTACT_EMAIL "Let's Encrypt ACME contact email" "altosecteam@gmail.com"
fi
read_val RUNNER_NAME           "Runner name (unique on GitHub)" ""
read_val REGISTRATION_TOKEN    "Registration token (GitHub -> New self-hosted runner)" ""
_existing_url=""
[[ -s "$DEPLOY_DIR/main-server-url.txt" ]] && _existing_url="$(cat "$DEPLOY_DIR/main-server-url.txt" | tr -d '\r\n' | xargs)"
read_val MAIN_SERVER_URL       "Main server URL (e.g. http://1.2.3.4:18000)" "$_existing_url"

# ── validation ────────────────────────────────────────────────────────────────
RUNNER_NAME="${RUNNER_NAME//[[:space:]]/}"
REGISTRATION_TOKEN="${REGISTRATION_TOKEN//[[:space:]]/}"
[[ -z "$RUNNER_NAME" ]]         && die "Runner name is required."
[[ -z "$REGISTRATION_TOKEN" ]]  && die "Registration token is required."
if $USE_TLS; then
  [[ -z "${DEPLOY_DOMAIN_FQDN:-}" ]] && die "FQDN is required for --tls."
  [[ "${ACME_CONTACT_EMAIL:-}" =~ @example\.(com|org|net)$ ]] \
    && die "Use a real ACME contact email (not @example.com/org/net)."
fi

info "=== Altosec Email Scheduler bootstrap ==="
info "Mode:       $(if $USE_TLS; then echo 'TLS'; else echo 'HTTP-only'; fi)"
info "Runner:     $RUNNER_NAME  →  $RUNNER_ROOT"
info "Deploy dir: $DEPLOY_DIR"
is_wsl && info "Environment: WSL2 detected"

# ── Step 1: Docker Engine ─────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Installing Docker Engine (apt)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  DISTRO_ID="$(. /etc/os-release && echo "${ID}")"
  DISTRO_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs)}")"
  mkdir -p /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  info "Docker Engine installed."
else
  info "Docker Engine already present ($(docker --version 2>/dev/null | head -1)). Skipping install."
fi

# Start Docker daemon if not already running (WSL2 has no auto-start without systemd).
if ! docker info &>/dev/null 2>&1; then
  info "Starting Docker daemon..."
  if is_wsl; then
    service docker start
  else
    systemctl enable --now docker
  fi
fi

# ── Step 2: Service user ──────────────────────────────────────────────────────
if [[ "$RUNNER_SVC_USER" != "root" ]]; then
  if ! id -u "$RUNNER_SVC_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RUNNER_SVC_USER"
    info "Created user $RUNNER_SVC_USER."
  fi
  usermod -aG docker "$RUNNER_SVC_USER"
fi

# ── Step 3: Environment variables ────────────────────────────────────────────
# Persist in /etc/environment (read by PAM / systemd EnvironmentFile)
set_sys_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" /etc/environment 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" /etc/environment
  else
    echo "${key}=${value}" >> /etc/environment
  fi
  export "${key}=${value}"
}
remove_sys_env() {
  sed -i "/^${1}=/d" /etc/environment 2>/dev/null || true
}

mkdir -p "$DEPLOY_DIR"
chown "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$DEPLOY_DIR"

set_sys_env "ALTOSEC_EMAIL_DEPLOY_DIR" "$DEPLOY_DIR"

if [[ -n "${MAIN_SERVER_URL:-}" ]]; then
  echo "$MAIN_SERVER_URL" > "$DEPLOY_DIR/main-server-url.txt"
  info "Saved MAIN_SERVER_URL → $DEPLOY_DIR/main-server-url.txt"
fi

if ! $USE_TLS; then
  set_sys_env "ALTOSEC_DEPLOY_HTTP_ONLY" "true"
  # Do not touch ALTOSEC_DEPLOY_DOMAIN — that belongs to proxy server on shared hosts.
  info "Env: ALTOSEC_DEPLOY_HTTP_ONLY=true  ALTOSEC_EMAIL_DEPLOY_DIR=$DEPLOY_DIR  (HTTP / IP)"
else
  remove_sys_env "ALTOSEC_DEPLOY_HTTP_ONLY"
  DEPLOY_DOMAIN_FQDN="${DEPLOY_DOMAIN_FQDN,,}"
  set_sys_env "ALTOSEC_EMAIL_DEPLOY_DOMAIN" "$DEPLOY_DOMAIN_FQDN"
  info "Env: ALTOSEC_EMAIL_DEPLOY_DOMAIN=$DEPLOY_DOMAIN_FQDN  ALTOSEC_EMAIL_DEPLOY_DIR=$DEPLOY_DIR  (TLS)"

  ACME_CONTACT_EMAIL="${ACME_CONTACT_EMAIL:-altosecteam@gmail.com}"
  echo "$ACME_CONTACT_EMAIL" > "$DEPLOY_DIR/acme-contact-email.txt"
  chown "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$DEPLOY_DIR/acme-contact-email.txt"
  info "Wrote ACME contact: $DEPLOY_DIR/acme-contact-email.txt"
fi

# ── Step 4: Firewall (ufw) ─────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  if $USE_TLS; then
    ufw allow 80/tcp  comment 'Altosec Email Scheduler ACME HTTP-01' 2>/dev/null || true
    ufw allow 443/tcp comment 'Altosec Email Scheduler HTTPS'        2>/dev/null || true
    info "UFW: opened TCP 80 (ACME), 443 (HTTPS)."
  else
    ufw allow 2026/tcp comment 'Altosec Email Scheduler API' 2>/dev/null || true
    info "UFW: opened TCP 2026 (HTTP API)."
  fi
else
  PORTS=$(if $USE_TLS; then echo "TCP 80, 443"; else echo "TCP 2026"; fi)
  warn "ufw not found — ensure your firewall / cloud security group allows $PORTS inbound."
fi

# ── Step 5: GitHub Actions runner ────────────────────────────────────────────
# Kill any Runner.Listener process running from our runner directory.
# Use path-specific match so other projects' runners are not affected.
pkill -f "${RUNNER_ROOT}/bin/Runner.Listener" 2>/dev/null || true
sleep 1

# Stop and uninstall any existing systemd service before wiping the directory.
if [[ -f "$RUNNER_ROOT/.service" ]]; then
  OLD_SVC="$(cat "$RUNNER_ROOT/.service")"
  systemctl stop    "$OLD_SVC" 2>/dev/null || true
  systemctl disable "$OLD_SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$OLD_SVC"
  systemctl daemon-reload 2>/dev/null || true
fi
# Always wipe the entire runner directory — the runner uses .credentials (not
# .runner) for IsConfigured(), so removing individual files is unreliable.
info "Removing $RUNNER_ROOT for clean install..."
rm -rf "$RUNNER_ROOT"
mkdir -p "$RUNNER_ROOT"

info "Downloading latest GitHub Actions runner (linux-x64)..."
RUNNER_REL="$(curl -fsSL \
  -H 'User-Agent: Altosec-EmailScheduler-RunnerBootstrap' \
  https://api.github.com/repos/actions/runner/releases/latest)"

RUNNER_URL="$(echo "$RUNNER_REL" | python3 -c "
import sys, json
rel = json.load(sys.stdin)
asset = next(
  (a for a in rel['assets']
   if 'linux-x64' in a['name'] and a['name'].endswith('.tar.gz')),
  None)
print(asset['browser_download_url'] if asset else '')
")"
[[ -z "$RUNNER_URL" ]] && die "Could not find linux-x64 runner tar.gz in latest release."

RUNNER_TAR="/tmp/actions-runner-linux.tar.gz"
info "Downloading: $RUNNER_URL"
curl -fsSL -o "$RUNNER_TAR" "$RUNNER_URL"
tar -xzf "$RUNNER_TAR" -C "$RUNNER_ROOT"
rm -f "$RUNNER_TAR"

chown -R "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$RUNNER_ROOT"

LABEL_LIST="self-hosted,Linux,altosec-proxy-node,$RUNNER_NAME"
info "Configuring runner  name=$RUNNER_NAME  labels=$LABEL_LIST"

export RUNNER_ALLOW_RUNASROOT=1
"$RUNNER_ROOT/config.sh" \
  --url "$REPO_URL" \
  --token "$REGISTRATION_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABEL_LIST" \
  --unattended \
  --replace
info "Runner configured."

# ── Step 6: Start runner ──────────────────────────────────────────────────────
if is_wsl; then
  # WSL2: no systemd. Use a retry-watchdog script: GitHub registration takes up
  # to ~2 minutes to propagate after config.sh — the first run.sh attempt gets
  # "registration deleted"; the watchdog retries until it succeeds.
  LOG_FILE="$DEPLOY_DIR/runner.log"
  WATCHDOG="$DEPLOY_DIR/runner-watchdog.sh"
  cat > "$WATCHDOG" << WATCHDOG_EOF
#!/bin/bash
export RUNNER_ALLOW_RUNASROOT=1
for attempt in 1 2 3 4 5; do
  echo "[\$(date)] Runner start attempt \$attempt" >> "$LOG_FILE"
  RUN_OUT=\$(mktemp)
  "$RUNNER_ROOT/run.sh" > "\$RUN_OUT" 2>&1
  cat "\$RUN_OUT" >> "$LOG_FILE"
  if grep -q 'runner registration has been deleted' "\$RUN_OUT"; then
    rm -f "\$RUN_OUT"
    echo "[\$(date)] GitHub registration not propagated yet — retrying in 60s (\$attempt/5)" >> "$LOG_FILE"
    sleep 60
  else
    rm -f "\$RUN_OUT"
    break
  fi
done
WATCHDOG_EOF
  chmod +x "$WATCHDOG"
  > "$LOG_FILE"
  nohup bash "$WATCHDOG" &
  RUNNER_PID=$!
  sleep 4
  if kill -0 "$RUNNER_PID" 2>/dev/null; then
    info "Runner watchdog started (PID $RUNNER_PID). Log: $LOG_FILE"
    info "Runner may auto-retry up to 5x if GitHub registration is still propagating."
  else
    die "Runner watchdog exited immediately. Check log: $LOG_FILE"
  fi
else
  # Bare-metal Linux: install and start as a systemd service.
  pushd "$RUNNER_ROOT" >/dev/null
  info "Installing runner as systemd service..."
  ./svc.sh install "$RUNNER_SVC_USER"
  ./svc.sh start
  info "Runner service installed and started."
  popd >/dev/null
fi

# ── Done ──────────────────────────────────────────────────────────────────────
SVC_STATUS="unknown"
if is_wsl; then
  pgrep -f 'Runner.Listener' &>/dev/null && SVC_STATUS="running" || SVC_STATUS="not running"
elif [[ -f "$RUNNER_ROOT/.service" ]]; then
  SVC_NAME="$(cat "$RUNNER_ROOT/.service")"
  SVC_STATUS="$(systemctl is-active "$SVC_NAME" 2>/dev/null || echo 'inactive')"
fi

info "=== Bootstrap complete ==="
info "Runner service status: $SVC_STATUS"
info "Next: verify runner shows Idle in GitHub → Altosec-email-scheduler → Settings → Runners"
info "Then: trigger the Deploy workflow (Actions → Deploy self-hosted Linux)."
