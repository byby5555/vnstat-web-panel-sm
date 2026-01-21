#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT=/var/www/vnstat-web
CFG=/etc/vnstat-web.conf

mkdir -p "$WEB_ROOT"

VNSTAT_BIN="${VNSTAT_BIN:-$(command -v vnstat || true)}"
VNSTATI_BIN="${VNSTATI_BIN:-$(command -v vnstati || true)}"

if [[ -z "${VNSTAT_BIN}" ]]; then
  echo "ERROR: vnstat not found. Please install vnstat."
  exit 1
fi

detect_iface() {
  # 1) default route interface (most reliable)
  local dev=""
  if command -v ip >/dev/null 2>&1; then
    dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  if [[ -n "${dev:-}" && "$dev" != "lo" ]]; then
    echo "$dev"
    return 0
  fi

  # 2) fallback: first non-virtual link
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|virbr|wg|tun|tap)' | head -n 1 && return 0
  fi

  return 1
}

IFACE=""
if [[ -f "$CFG" ]]; then
  IFACE="$(grep -E '^interface=' "$CFG" | head -n1 | cut -d= -f2- | tr -d ' \r\n' || true)"
fi
if [[ -z "$IFACE" ]]; then
  IFACE="$(detect_iface || true)"
fi
# final fallback: vnstat --iflist first entry
if [[ -z "$IFACE" ]]; then
  IFACE="$("$VNSTAT_BIN" --iflist | head -n1 | sed 's/^Available interfaces: //' | awk '{print $1}')"
fi
if [[ -z "$IFACE" ]]; then
  echo "ERROR: cannot detect interface"
  exit 1
fi


"$VNSTAT_BIN" -u -i "$IFACE" || true

"$VNSTAT_BIN" --json > "$WEB_ROOT/vnstat.json"
cp -f "$WEB_ROOT/vnstat.json" "$WEB_ROOT/vnstat_5min.json"

{
  echo "Interface: $IFACE"
  echo "UpdatedUTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  "$VNSTAT_BIN" -i "$IFACE" || true
} > "$WEB_ROOT/summary.txt"

SERVER_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
SERVER_TIME_ISO="$(date +%Y-%m-%dT%H:%M:%S)"
SERVER_UTC_OFFSET="$(date +%z)"
printf '{"server_time_iso":"%s","server_tz":"%s","server_utc_offset":"%s"}\n' "$SERVER_TIME_ISO" "${SERVER_TZ:-}" "$SERVER_UTC_OFFSET" > "$WEB_ROOT/server_time.json"

chmod 644   "$WEB_ROOT/vnstat.json"   "$WEB_ROOT/vnstat_5min.json"   "$WEB_ROOT/summary.txt"   "$WEB_ROOT/server_time.json"

if [[ -n "${VNSTATI_BIN}" ]]; then
  "$VNSTATI_BIN" -h -i "$IFACE" -o "$WEB_ROOT/hourly.png"
  "$VNSTATI_BIN" -d -i "$IFACE" -o "$WEB_ROOT/daily.png"
  "$VNSTATI_BIN" -m -i "$IFACE" -o "$WEB_ROOT/monthly.png"
  chmod 644 "$WEB_ROOT/hourly.png" "$WEB_ROOT/daily.png" "$WEB_ROOT/monthly.png"
else
  echo "WARN: vnstati not found; skip png generation"
fi
