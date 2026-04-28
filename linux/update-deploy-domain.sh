#!/usr/bin/env bash
# Altosec Email Scheduler — Linux / WSL2: update TLS deploy domain without
# re-registering the runner.
#
# Updates ALTOSEC_EMAIL_DEPLOY_DOMAIN in /etc/environment and restarts the
# runner service so the Deploy workflow picks up the new FQDN on the next run.
#
# Does NOT touch ALTOSEC_DEPLOY_DOMAIN (proxy server's variable on shared hosts).
#
# Usage:
#   sudo bash scripts/linux/update-deploy-domain.sh [--fqdn new.example.com]
#
# Options:
#   --fqdn <fqdn>   New public FQDN. If omitted, prompts interactively.

set -euo pipefail

die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"

NEW_FQDN=""
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner-email-scheduler}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) NEW_FQDN="$2"; shift 2 ;;
    *)      die "Unknown argument: $1" ;;
  esac
done

if [[ -z "$NEW_FQDN" ]]; then
  read -rp "New public FQDN (DNS A -> this server): " NEW_FQDN </dev/tty
fi

NEW_FQDN="${NEW_FQDN//[[:space:]]/}"
NEW_FQDN="${NEW_FQDN,,}"
[[ -z "$NEW_FQDN" ]] && die "FQDN is required."

# Update /etc/environment (idempotent)
if grep -q "^ALTOSEC_EMAIL_DEPLOY_DOMAIN=" /etc/environment 2>/dev/null; then
  sed -i "s|^ALTOSEC_EMAIL_DEPLOY_DOMAIN=.*|ALTOSEC_EMAIL_DEPLOY_DOMAIN=${NEW_FQDN}|" /etc/environment
else
  echo "ALTOSEC_EMAIL_DEPLOY_DOMAIN=${NEW_FQDN}" >> /etc/environment
fi
export ALTOSEC_EMAIL_DEPLOY_DOMAIN="$NEW_FQDN"
info "ALTOSEC_EMAIL_DEPLOY_DOMAIN=$NEW_FQDN  (proxy ALTOSEC_DEPLOY_DOMAIN unchanged)"

# Restart runner service
SVC_FILE="$RUNNER_ROOT/.service"
if [[ -f "$SVC_FILE" ]]; then
  SVC_NAME="$(cat "$SVC_FILE")"
  if command -v systemctl &>/dev/null; then
    systemctl restart "$SVC_NAME"
    info "Runner service '$SVC_NAME' restarted."
  else
    pushd "$RUNNER_ROOT" >/dev/null
    ./svc.sh stop  || true
    ./svc.sh start || true
    popd >/dev/null
    info "Runner service restarted via svc.sh."
  fi
else
  info "Runner service file not found at $SVC_FILE — restart the runner manually."
fi

echo ""
info "Next step (required): GitHub → Actions → Deploy self-hosted Linux → workflow_dispatch"
info "The job will read the new domain, re-run certbot if needed, and restart Docker Compose."
