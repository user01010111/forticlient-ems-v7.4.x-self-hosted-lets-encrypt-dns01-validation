#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
EMAIL=""
CF_CREDS="/root/.secrets/certbot/cloudflare.ini"
DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/fcems-cert-deploy.sh"
EMS_REFRESH="/usr/local/sbin/fcems-ems-refresh.sh"
WRAPPER="/usr/local/sbin/fcems-certbot.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/setup.sh --domain ems.example.com --email admin@example.com
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  usage
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare

install -d -m 700 /root/.secrets/certbot
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
install -d -m 755 /usr/local/sbin

cat > "$CF_CREDS" <<'EOF'
# Cloudflare API token with:
# - Zone:DNS:Edit
# - Zone:Zone:Read
dns_cloudflare_api_token = REPLACE_ME
EOF
chmod 600 "$CF_CREDS"

cat > "$DEPLOY_HOOK" <<EOF
#!/usr/bin/env bash
set -euo pipefail

log() {
  logger -t fcems-cert-deploy "\$*"
  echo "\$*"
}

LIVE_DIR="\${RENEWED_LINEAGE:-/etc/letsencrypt/live/$DOMAIN}"
SRC_CERT="\$LIVE_DIR/fullchain.pem"
SRC_KEY="\$LIVE_DIR/privkey.pem"
DST_DIR="/opt/forticlientems/data/certs"
DST_CERT="\$DST_DIR/$DOMAIN.crt"
DST_KEY="\$DST_DIR/$DOMAIN.key"
TMP_CERT="\$DST_CERT.tmp.\$\$"
TMP_KEY="\$DST_KEY.tmp.\$\$"

if [[ ! -s "\$SRC_CERT" || ! -s "\$SRC_KEY" ]]; then
  log "source certificate files are missing from \$LIVE_DIR"
  exit 1
fi

# Defensive safeguard: never publish a non-production cert into EMS.
if openssl x509 -in "\$SRC_CERT" -noout -issuer | grep -q '(STAGING)'; then
  log "refusing to deploy non-production certificate from \$LIVE_DIR"
  exit 0
fi

install -m 770 -o forticlientems -g forticlientems /dev/null "\$TMP_CERT"
install -m 770 -o forticlientems -g forticlientems /dev/null "\$TMP_KEY"
cat "\$SRC_CERT" > "\$TMP_CERT"
cat "\$SRC_KEY" > "\$TMP_KEY"
chown forticlientems:forticlientems "\$TMP_CERT" "\$TMP_KEY"
chmod 770 "\$TMP_CERT" "\$TMP_KEY"

mv -f "\$TMP_CERT" "\$DST_CERT"
mv -f "\$TMP_KEY" "\$DST_KEY"

apachectl configtest >/dev/null
systemctl reload apache2

log "deployed renewed certificate from \$LIVE_DIR into EMS and reloaded apache2"
EOF
chmod 755 "$DEPLOY_HOOK"

cat > "$EMS_REFRESH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

services=$(systemctl list-unit-files 'fcems_*.service' --state=enabled --no-legend | awk '{print $1}')

if [[ -z "$services" ]]; then
  echo "no enabled EMS services found" >&2
  exit 1
fi

systemctl restart $services

# Let the restart burst complete before any cert deployment happens.
sleep 45

for _ in $(seq 1 18); do
  if ps -eo etimes,cmd | awk '/fcems_|apache2 -k start/ && !/awk/ { if ($1 < 20) found=1 } END { exit found ? 0 : 1 }'; then
    sleep 10
  else
    break
  fi
done
EOF
chmod 755 "$EMS_REFRESH"

cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
CF_CREDS="$CF_CREDS"
DEPLOY_HOOK="$DEPLOY_HOOK"
EMS_REFRESH="$EMS_REFRESH"

usage() {
  cat <<'EOS'
Usage:
  fcems-certbot.sh issue
  fcems-certbot.sh renew
  fcems-certbot.sh deploy-now
  fcems-certbot.sh restart-ems-then-deploy
  fcems-certbot.sh verify
EOS
}

require_token() {
  if [[ ! -f "\$CF_CREDS" ]]; then
    echo "missing credential file: \$CF_CREDS" >&2
    exit 1
  fi
  if grep -Eq '^dns_cloudflare_api_token\\s*=\\s*REPLACE_ME$' "\$CF_CREDS"; then
    echo "Cloudflare token placeholder still present in \$CF_CREDS" >&2
    exit 1
  fi
}

cmd="\${1:-}"
case "\$cmd" in
  issue)
    require_token
    exec certbot certonly \\
      --non-interactive \\
      --agree-tos \\
      --email "\$EMAIL" \\
      --dns-cloudflare \\
      --dns-cloudflare-credentials "\$CF_CREDS" \\
      --dns-cloudflare-propagation-seconds 60 \\
      --deploy-hook "\$DEPLOY_HOOK" \\
      --cert-name "\$DOMAIN" \\
      -d "\$DOMAIN"
    ;;
  renew)
    require_token
    exec certbot renew
    ;;
  deploy-now)
    exec "\$DEPLOY_HOOK"
    ;;
  restart-ems-then-deploy)
    "\$EMS_REFRESH"
    exec "\$DEPLOY_HOOK"
    ;;
  verify)
    echo "LIVE443"
    echo | openssl s_client -connect "\$DOMAIN:443" -servername "\$DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -serial
    echo "---"
    echo "LIVE10443"
    echo | openssl s_client -connect 127.0.0.1:10443 -servername "\$DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -serial
    echo "---"
    echo "EMS_FILE"
    openssl x509 -in "/opt/forticlientems/data/certs/\$DOMAIN.crt" -noout -subject -issuer -dates -serial
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOF
chmod 755 "$WRAPPER"

systemctl enable --now certbot.timer

cat <<EOF
Setup complete.

Next steps:
  1. sudoedit $CF_CREDS
  2. sudo $WRAPPER issue
  3. sudo $WRAPPER verify
EOF
