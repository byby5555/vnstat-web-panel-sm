#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT="${WEB_ROOT:-/var/www/vnstat-web}"
VNSTAT_BIN="${VNSTAT_BIN:-vnstat}"
VNSTATI_BIN="${VNSTATI_BIN:-vnstati}"
CFG="${CFG:-/etc/vnstat-web.conf}"

mkdir -p "$WEB_ROOT"

# 选网卡：优先 /etc/vnstat-web.conf 里的 interface=xxx，否则取 vnstat --iflist 第一个
IFACE="$(grep -E '^interface=' "$CFG" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' \r\n' || true)"
if [[ -z "${IFACE:-}" ]]; then
  IFLIST="$("$VNSTAT_BIN" --iflist | sed 's/^Available interfaces: //')"
  IFACE="$(printf "%s\n" "$IFLIST" | awk '{print $1}')"
fi
IFACE="${IFACE:-eth0}"

# 1) JSON（页面 fetch vnstat.json / vnstat_5min.json）
"$VNSTAT_BIN" --json > "${WEB_ROOT}/vnstat.json"
cp -f "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json"

# 2) summary.txt（页面 fetch summary.txt）
{
  echo "Interface: ${IFACE}"
  echo "Updated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  "$VNSTAT_BIN" -i "$IFACE" 2>/dev/null || true
} > "${WEB_ROOT}/summary.txt"

chmod 644 "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json" "${WEB_ROOT}/summary.txt"

# 3) PNG（页面加载 hourly.png / daily.png / monthly.png）
"$VNSTATI_BIN" -h -i "$IFACE" -o "${WEB_ROOT}/hourly.png"
"$VNSTATI_BIN" -d -i "$IFACE" -o "${WEB_ROOT}/daily.png"
"$VNSTATI_BIN" -m -i "$IFACE" -o "${WEB_ROOT}/monthly.png"
chmod 644 "${WEB_ROOT}/hourly.png" "${WEB_ROOT}/daily.png" "${WEB_ROOT}/monthly.png"
