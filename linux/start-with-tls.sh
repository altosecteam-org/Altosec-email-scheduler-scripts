#!/usr/bin/env bash
# Altosec Email Scheduler — Linux / WSL2: certbot TLS + docker compose HTTPS.
#
# What this script does:
#   1. Ensures the UFW firewall allows TCP 80 and 443.
#   2. Optionally validates that the domain's A record resolves to this host's public IP.
#   3. Obtains a Let's Encrypt certificate with certbot standalone (HTTP-01 on port 80).
#      Skipped if fullchain.pem + privkey.pem already exist under <deploy-root>/certs/<domain>/.
#   4. Starts docker compose with docker-compose.tls.yml merged in (uvicorn HTTPS on 443).
#      Uses network_mode: host so the container binds directly to the host port — on Linux
#      and WSL2-mirrored this gives the container access to real client IPs.
#
# Requirements: root (certbot needs to bind port 80 for HTTP-01 challenge).
#
# Usage:
#   sudo bash scripts/linux/start-with-tls.sh \
#     --domain mail.example.com --email acme@example.com [options]
#
# Options:
#   --domain  <fqdn>      Required. Public FQDN for the certificate.
#   --email   <email>     Required. ACME contact address (Let's Encrypt notifications).
#   --skip-dns-check      Skip A-record vs public-IP validation.
#   --skip-docker         Stop after certbot (do not start compose).
#   --use-ghcr-image      Use docker-compose.ghcr.yml (pull from GHCR) instead of local build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"

# ── parse arguments ───────────────────────────────────────────────────────────
DOMAIN=""
EMAIL=""
SKIP_DNS_CHECK=false
SKIP_DOCKER=false
USE_GHCR_IMAGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)         DOMAIN="$2";       shift 2 ;;
    --email)          EMAIL="$2";        shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=true; shift ;;
    --skip-docker)    SKIP_DOCKER=true;  shift ;;
    --use-ghcr-image) USE_GHCR_IMAGE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$DOMAIN" ]] && die "--domain <fqdn> is required."
[[ -z "$EMAIL"  ]] && die "--email <acme-contact> is required."

DOMAIN="${DOMAIN,,}"
COMPOSE_BASE="$( $USE_GHCR_IMAGE && echo 'docker-compose.ghcr.yml' || echo 'docker-compose.yml' )"

CERT_DIR="$DEPLOY_ROOT/certs/$DOMAIN"
mkdir -p "$CERT_DIR"
export TLS_CERT_DIR="$CERT_DIR"

FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"

# ── firewall ──────────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  ufw allow 80/tcp  comment 'Altosec Email Scheduler ACME HTTP-01' 2>/dev/null || true
  ufw allow 443/tcp comment 'Altosec Email Scheduler HTTPS'        2>/dev/null || true
  info "UFW: TCP 80 and 443 allowed."
fi

# ── DNS check ─────────────────────────────────────────────────────────────────
get_public_ip() {
  curl -fsSL --max-time 15 https://api.ipify.org || \
  curl -fsSL --max-time 15 https://ipv4.icanhazip.com || \
  echo ""
}

if ! $SKIP_DNS_CHECK; then
  if ! command -v dig &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dnsutils -qq
  fi
  PUB_IP="$(get_public_ip)"
  if [[ -z "$PUB_IP" ]]; then
    info "Could not determine public IP — skipping DNS validation."
  else
    DNS_IPS="$(dig +short A "$DOMAIN" 2>/dev/null | tr '\n' ' ')"
    if [[ -z "$DNS_IPS" ]]; then
      die "No A record for '$DOMAIN'. Point the domain to this host's public IP ($PUB_IP) first."
    fi
    if ! echo "$DNS_IPS" | grep -qF "$PUB_IP"; then
      die "DNS mismatch: '$DOMAIN' A -> $DNS_IPS  but this host's public IPv4 is $PUB_IP. Fix DNS, wait for propagation, then retry."
    fi
    info "DNS OK: $DOMAIN -> $PUB_IP"
  fi
fi

# ── certbot ───────────────────────────────────────────────────────────────────
have_certs() {
  [[ -s "$FULLCHAIN" && -s "$PRIVKEY" ]]
}

if have_certs; then
  info "Existing fullchain.pem / privkey.pem found; skipping certbot."
else
  # Install certbot if not present (idempotent)
  if ! command -v certbot &>/dev/null; then
    info "Installing certbot..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends certbot
  fi

  # Free port 80 so certbot standalone can bind to it
  if ! $SKIP_DOCKER; then
    info "Stopping compose stacks (free port 80 for certbot)..."
    cd "$DEPLOY_ROOT"
    docker compose -f "$COMPOSE_BASE" -f docker-compose.tls.yml down 2>/dev/null || true
    docker compose -f "$COMPOSE_BASE" down 2>/dev/null || true
  else
    info "SkipDocker: ensure nothing is listening on port 80 before certbot runs."
  fi

  info "Running certbot standalone (port 80 must be free on this host)..."
  certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --domain "$DOMAIN"

  # Certbot writes to /etc/letsencrypt/live/<domain>/. Copy to our cert dir.
  LE_LIVE="/etc/letsencrypt/live/$DOMAIN"
  if [[ -d "$LE_LIVE" ]]; then
    # -L dereferences the symlinks certbot creates
    cp -L "$LE_LIVE/fullchain.pem" "$FULLCHAIN"
    cp -L "$LE_LIVE/privkey.pem"   "$PRIVKEY"
    info "Copied certs from $LE_LIVE to $CERT_DIR."
  fi

  have_certs || die "certbot ran but PEM files are missing at $CERT_DIR."
  info "TLS certificates obtained."
fi

# Guard
have_certs || die "TLS files still missing at $CERT_DIR. Cannot start Docker."

if $SKIP_DOCKER; then
  info "SkipDocker: PEMs ready at $CERT_DIR (fullchain.pem, privkey.pem). Docker not started."
  exit 0
fi

# ── docker compose up (TLS) ───────────────────────────────────────────────────
info "TLS_CERT_DIR=$TLS_CERT_DIR"

cd "$DEPLOY_ROOT"
info "Stopping existing compose stack (idempotent redeploy)..."
docker compose -f "$COMPOSE_BASE" -f docker-compose.tls.yml down 2>/dev/null || true
docker rm -f altosec_email_worker 2>/dev/null || true

info "Starting Docker Compose (HTTPS on host port 443, network_mode: host)..."
if $USE_GHCR_IMAGE; then
  docker compose -f "$COMPOSE_BASE" -f docker-compose.tls.yml pull
  docker compose -f "$COMPOSE_BASE" -f docker-compose.tls.yml up -d
else
  docker compose -f "$COMPOSE_BASE" -f docker-compose.tls.yml up -d --build
fi

info "Done. https://$DOMAIN/ (port 443, bound directly to host via network_mode: host)."
