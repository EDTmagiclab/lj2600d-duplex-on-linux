#!/usr/bin/env bash
#
# Remove the duplex filter, driver definition and config file.
#
# Copyright 2026 lj2600d-duplex contributors -- GPL-2.0-or-later
#
set -euo pipefail

QUEUE=""
PURGE_QUEUE=0

usage() {
  cat <<'EOF'
Usage: sudo bash uninstall.sh [--queue NAME] [--purge-queue]

  --queue NAME    Also act on this CUPS queue
  --purge-queue   Delete the queue as well (default: keep it)
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue)       QUEUE="${2:?--queue needs a value}"; shift 2 ;;
    --purge-queue) PURGE_QUEUE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root.  Try: sudo bash uninstall.sh" >&2
  exit 1
fi

for path in /usr/lib/cups/filter/rastertobrlaser-duplex \
            /usr/share/cups/drv/lj2600d-duplex.drv \
            /etc/cups/lj2600d-duplex.conf; do
  if [ -e "${path}" ]; then
    rm -f "${path}"
    echo "removed ${path}"
  fi
done

if [ -n "${QUEUE}" ] && [ "${PURGE_QUEUE}" -eq 1 ]; then
  if lpstat -p "${QUEUE}" >/dev/null 2>&1; then
    lpadmin -x "${QUEUE}"
    echo "deleted queue ${QUEUE}"
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups
else
  service cups restart
fi

echo "Done."
echo
echo "The queues that still point at this driver will stop printing until they"
echo "are recreated with another model, for example:"
echo "  sudo lpadmin -p ${QUEUE:-LJ2600D} -m drv:///brlaser.drv/br2140.ppd"
