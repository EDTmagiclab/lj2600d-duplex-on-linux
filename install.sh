#!/usr/bin/env bash
#
# Install the duplex-capable brlaser filter and (optionally) create a CUPS
# queue for a Lenovo LJ2600D / Brother HBP printer with a duplex unit.
#
# Copyright 2026 lj2600d-duplex contributors -- GPL-2.0-or-later
#
set -euo pipefail

QUEUE="LJ2600D"
DEVICE=""
MODEL="LJ2600D"
DEFAULT_MODE="duplex-long-edge"
CREATE_QUEUE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_SRC="${HERE}/filters/rastertobrlaser-duplex"
DRV_SRC="${HERE}/driver/lj2600d-duplex.drv"
DRV_NAME="$(basename "${DRV_SRC}")"

FILTER_DST="/usr/lib/cups/filter/rastertobrlaser-duplex"
DRV_DST="/usr/share/cups/drv/${DRV_NAME}"
CONF_DST="/etc/cups/lj2600d-duplex.conf"

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [options]

  --queue NAME       CUPS queue name to create or update (default: LJ2600D)
  --model NAME       LJ2600D | LJ2650DN | HL-2140   (default: LJ2600D)
  --device URI       Printer device URI, e.g. usb://Lenovo/LJ2600D
                     (default: auto-detect a USB Lenovo LJ2600D)
  --default MODE     duplex-long-edge | duplex-short-edge | simplex
                     (default: duplex-long-edge)
  --no-queue         Only install the filter and driver definition,
                     do not touch any print queue
  -h, --help         Show this help

Examples:
  sudo bash install.sh
  sudo bash install.sh --queue Office --default simplex
  sudo bash install.sh --device usb://Lenovo/LJ2600D?serial=ABC123
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue)     QUEUE="${2:?--queue needs a value}"; shift 2 ;;
    --model)     MODEL="${2:?--model needs a value}"; shift 2 ;;
    --device)    DEVICE="${2:?--device needs a value}"; shift 2 ;;
    --default)   DEFAULT_MODE="${2:?--default needs a value}"; shift 2 ;;
    --no-queue)  CREATE_QUEUE=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${MODEL}" in
  LJ2600D)  MODEL_PPD="lj2600d.ppd" ;;
  LJ2650DN) MODEL_PPD="lj2650dn.ppd" ;;
  HL-2140)  MODEL_PPD="hl2140-duplex.ppd" ;;
  *) echo "--model must be LJ2600D, LJ2650DN or HL-2140" >&2; exit 2 ;;
esac
MODEL_URI="drv:///${DRV_NAME}/${MODEL_PPD}"

case "${DEFAULT_MODE}" in
  duplex-long-edge|duplex-short-edge|simplex) ;;
  *) echo "--default must be duplex-long-edge, duplex-short-edge or simplex" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root.  Try: sudo bash install.sh" >&2
  exit 1
fi

say() { printf '  %s\n' "$*"; }

echo "==> Checking prerequisites"
if [ ! -x /usr/lib/cups/filter/rastertobrlaser ]; then
  echo "brlaser is not installed.  On Debian/Ubuntu:" >&2
  echo "    sudo apt install printer-driver-brlaser" >&2
  echo "On Fedora:" >&2
  echo "    sudo dnf install brlaser" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required by the filter." >&2
  exit 1
fi
say "brlaser found, python3 found"

echo "==> Installing files"
install -D -m 0755 -o root -g root "${FILTER_SRC}" "${FILTER_DST}"
say "${FILTER_DST}"
install -D -m 0644 -o root -g root "${DRV_SRC}" "${DRV_DST}"
say "${DRV_DST}"

printf '# Default duplex mode used when a job does not say.\n# One of: duplex-long-edge, duplex-short-edge, simplex\ndefault = %s\n' \
  "${DEFAULT_MODE}" > "${CONF_DST}"
chmod 0644 "${CONF_DST}"
say "${CONF_DST} (default = ${DEFAULT_MODE})"

echo "==> Restarting CUPS"
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups
else
  service cups restart
fi
sleep 1

if [ "${CREATE_QUEUE}" -eq 0 ]; then
  echo
  echo "Done.  Filter and driver installed; no queue was created."
  echo "Add one with:"
  echo "  sudo lpadmin -p ${QUEUE} -E -v usb://Lenovo/LJ2600D \\"
  echo "        -m ${MODEL_URI} -o PageSize=A4"
  exit 0
fi

echo "==> Preparing print queue '${QUEUE}'"
if [ -z "${DEVICE}" ]; then
  DEVICE="$(lpinfo -v 2>/dev/null | awk '/^direct usb:/ && /[Ll]enovo|LJ2600/ {print $2; exit}')"
  if [ -z "${DEVICE}" ]; then
    echo "Could not detect a USB Lenovo printer.  Pass one with --device, e.g." >&2
    echo "    --device usb://Lenovo/LJ2600D" >&2
    echo >&2
    echo "Available devices:" >&2
    lpinfo -v >&2 || true
    exit 1
  fi
fi
say "device ${DEVICE}"

if lpstat -p "${QUEUE}" >/dev/null 2>&1; then
  say "queue exists, updating driver"
  lpadmin -p "${QUEUE}" -E -v "${DEVICE}" -m "${MODEL_URI}" -o PageSize=A4
else
  lpadmin -p "${QUEUE}" -E -v "${DEVICE}" -m "${MODEL_URI}" \
    -o PageSize=A4 -o printer-is-shared=true
  say "queue created"
fi

cupsenable "${QUEUE}"
cupsaccept "${QUEUE}"

echo
echo "Done."
echo
echo "  Queue   : ${QUEUE}"
echo "  Model   : ${MODEL} (${MODEL_PPD})"
echo "  Default : ${DEFAULT_MODE}"
echo
echo "Send a test page (two pages, both sides of one sheet):"
echo "  lp -d ${QUEUE} /usr/share/cups/data/default-testpage.pdf"
echo
echo "One-sided for a single job:   lp -d ${QUEUE} -o Duplex=None FILE"
echo "Change the default later by editing ${CONF_DST}"
