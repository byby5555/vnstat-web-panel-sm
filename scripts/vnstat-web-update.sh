#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT="${WEB_ROOT:-/var/www/vnstat-web}"
VNSTAT_BIN="${VNSTAT_BIN:-/usr/bin/vnstat}"
VNSTATI_BIN="${VNSTATI_BIN:-/usr/bin/vnstati}"
CFG="${CFG:-/etc/vnstat-web.conf}"

mkdir -p "$WEB_ROOT"

# iface: prefer config, else first from vnstat --iflist
IFACE=""
if [[ -f "$CFG" ]]; then
  IFACE="$(grep -E '^interface=' "$CFG" | head -n1 | cut -d= -f2- | tr -d ' \r\n' || true)"
fi
if [[ -z "${IFACE}" ]]; then
  IFACE="$("$VNSTAT_BIN" --iflist 2>/dev/null | sed 's/^Available interfaces: //' | awk '{print $1}' | head -n1 || true)"
fi
IFACE="${IFACE:-eth0}"

# Ensure vnstat db entry exists/updated for the iface
"$VNSTAT_BIN" -u -i "$IFACE" >/dev/null 2>&1 || true

# vnstat json
"$VNSTAT_BIN" --json > "${WEB_ROOT}/vnstat.json"
cp -f "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json"

# summary.txt
{
  echo "Interface: ${IFACE}"
  echo "UpdatedUTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  "$VNSTAT_BIN" -i "$IFACE" 2>/dev/null || true
} > "${WEB_ROOT}/summary.txt"

# server_time.json (frontend fetches this)
SERVER_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ -z "${SERVER_TZ}" ]]; then
  SERVER_TZ="$(date +%Z)"
fi
SERVER_TIME_ISO="$(date '+%Y-%m-%dT%H:%M:%S')"
SERVER_UTC_OFFSET="$(date '+%z')"
printf '{"server_time_iso":"%s","server_tz":"%s","server_utc_offset":"%s"}\n' \
  "$SERVER_TIME_ISO" "$SERVER_TZ" "$SERVER_UTC_OFFSET" > "${WEB_ROOT}/server_time.json"

chmod 644 "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json" "${WEB_ROOT}/summary.txt" "${WEB_ROOT}/server_time.json"

# png (need vnstati)
"$VNSTAT_BIN" -u -i "$IFACE" >/dev/null 2>&1 || true
"$VNSTATI_BIN" -h -i "$IFACE" -o "${WEB_ROOT}/hourly.png"
"$VNSTATI_BIN" -d -i "$IFACE" -o "${WEB_ROOT}/daily.png"
"$VNSTATI_BIN" -m -i "$IFACE" -o "${WEB_ROOT}/monthly.png"
chmod 644 "${WEB_ROOT}/hourly.png" "${WEB_ROOT}/daily.png" "${WEB_ROOT}/monthly.png"
