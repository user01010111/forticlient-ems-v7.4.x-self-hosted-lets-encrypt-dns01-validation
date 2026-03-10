#!/usr/bin/env bash
set -euo pipefail

mode="${1:-apache}"
domain="${2:-}"

deploy_now() {
  if [[ -z "$domain" ]]; then
    echo "domain argument required for deploy actions" >&2
    exit 1
  fi

  local live_dir="/etc/letsencrypt/live/$domain"
  local dst_dir="/opt/forticlientems/data/certs"
  local tmp_crt="$dst_dir/$domain.crt.tmp.$$"
  local tmp_key="$dst_dir/$domain.key.tmp.$$"

  install -m 770 -o forticlientems -g forticlientems /dev/null "$tmp_crt"
  install -m 770 -o forticlientems -g forticlientems /dev/null "$tmp_key"
  cat "$live_dir/fullchain.pem" > "$tmp_crt"
  cat "$live_dir/privkey.pem" > "$tmp_key"
  chown forticlientems:forticlientems "$tmp_crt" "$tmp_key"
  chmod 770 "$tmp_crt" "$tmp_key"
  mv -f "$tmp_crt" "$dst_dir/$domain.crt"
  mv -f "$tmp_key" "$dst_dir/$domain.key"
  apachectl configtest >/dev/null
  systemctl reload apache2
}

restart_suite() {
  local services
  services=$(systemctl list-unit-files 'fcems_*.service' --state=enabled --no-legend | awk '{print $1}')

  if [[ -z "$services" ]]; then
    echo "no enabled EMS services found" >&2
    exit 1
  fi

  systemctl restart $services
  sleep 45

  for _ in $(seq 1 18); do
    if ps -eo etimes,cmd | awk '/fcems_|apache2 -k start/ && !/awk/ { if ($1 < 20) found=1 } END { exit found ? 0 : 1 }'; then
      sleep 10
    else
      break
    fi
  done
}

case "$mode" in
  apache)
    systemctl reload apache2
    ;;
  suite)
    restart_suite
    ;;
  deploy-now)
    deploy_now
    ;;
  suite-and-deploy)
    restart_suite
    deploy_now
    ;;
  *)
    echo "Usage: sudo ./scripts/reload-ems.sh [apache|suite|deploy-now|suite-and-deploy] [domain]" >&2
    exit 1
    ;;
esac
