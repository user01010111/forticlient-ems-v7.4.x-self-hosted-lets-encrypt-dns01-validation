#!/usr/bin/env bash
set -euo pipefail

mode="${1:-apache}"

case "$mode" in
  apache)
    systemctl reload apache2
    ;;
  monitor)
    systemctl restart fcems_monitor
    ;;
  all)
    systemctl restart apache2
    systemctl restart fcems_monitor
    systemctl restart fcems_reg
    systemctl restart fcems_task
    systemctl restart fcems_update
    systemctl restart fcems_ztna
    ;;
  *)
    echo "Usage: sudo ./scripts/reload-ems.sh [apache|monitor|all]" >&2
    exit 1
    ;;
esac
