#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT=/var/www/vnstat-web
CFG=/etc/vnstat-web.conf
QUOTA_CONF=/etc/vnstat-web/quota.json

if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

WEB_ROOT="${WEB_ROOT:-${WEB_PATH:-/var/www/vnstat-web}}"
FIVE_MIN_POINTS="${FIVE_MIN_POINTS:-288}"
QUOTA_GB="${QUOTA_GB:-1024}"
ALERT_PCT="${ALERT_PCT:-90}"
DANGER_PCT="${DANGER_PCT:-100}"

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

IFACE="${IFACE:-}"
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

"$VNSTAT_BIN" --json -i "$IFACE" > "$WEB_ROOT/vnstat.json"
if "$VNSTAT_BIN" --json f "$FIVE_MIN_POINTS" -i "$IFACE" > "$WEB_ROOT/vnstat_5min.json.tmp"; then
  mv "$WEB_ROOT/vnstat_5min.json.tmp" "$WEB_ROOT/vnstat_5min.json"
else
  rm -f "$WEB_ROOT/vnstat_5min.json.tmp"
  cp -f "$WEB_ROOT/vnstat.json" "$WEB_ROOT/vnstat_5min.json"
fi

{
  echo "Interface: $IFACE"
  echo "UpdatedUTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  "$VNSTAT_BIN" -i "$IFACE" || true
} > "$WEB_ROOT/summary_en.txt"

if [[ -f "$WEB_ROOT/summary_en.txt" ]]; then
  sed -e 's/^Interface:/网卡:/g' \
      -e 's/^UpdatedUTC:/更新时间(UTC):/g' \
      -e 's/Database updated/数据库更新时间/g' \
      -e 's/selected interface/当前网卡/g' \
      -e 's/ since / 自 /g' \
      -e 's/ avg\\. rate/ 平均速率/g' \
      -e 's/ average rate/ 平均速率/g' \
      -e 's/ rx:/ 下行:/g' \
      -e 's/ tx:/ 上行:/g' \
      -e 's/ total:/ 合计:/g' \
      -e 's/ estimated/ 预估/g' \
      -e 's/ daily/ 每日/g' \
      -e 's/ monthly/ 每月/g' \
      -e 's/ yearly/ 每年/g' \
      -e 's/ last 7 days/ 最近7天/g' \
      "$WEB_ROOT/summary_en.txt" > "$WEB_ROOT/summary.txt"
else
  cp -f "$WEB_ROOT/summary_en.txt" "$WEB_ROOT/summary.txt"
fi

SERVER_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
SERVER_TIME_ISO="$(date +%Y-%m-%dT%H:%M:%S)"
SERVER_UTC_OFFSET="$(date +%z)"
printf '{"server_time_iso":"%s","server_tz":"%s","server_utc_offset":"%s"}\n' "$SERVER_TIME_ISO" "${SERVER_TZ:-}" "$SERVER_UTC_OFFSET" > "$WEB_ROOT/server_time.json"

chmod 644   "$WEB_ROOT/vnstat.json"   "$WEB_ROOT/vnstat_5min.json"   "$WEB_ROOT/summary.txt"   "$WEB_ROOT/summary_en.txt"   "$WEB_ROOT/server_time.json"

if [[ -f "$QUOTA_CONF" ]]; then
  cp -f "$QUOTA_CONF" "$WEB_ROOT/quota.json"
else
  printf '{"quota_gb":%s,"alert_pct":%s,"danger_pct":%s}\n' "$QUOTA_GB" "$ALERT_PCT" "$DANGER_PCT" > "$WEB_ROOT/quota.json"
fi
chmod 644 "$WEB_ROOT/quota.json"

if [[ -n "${VNSTATI_BIN}" ]]; then
  "$VNSTATI_BIN" -h -i "$IFACE" -o "$WEB_ROOT/hourly.png"
  "$VNSTATI_BIN" -d -i "$IFACE" -o "$WEB_ROOT/daily.png"
  "$VNSTATI_BIN" -m -i "$IFACE" -o "$WEB_ROOT/monthly.png"
  chmod 644 "$WEB_ROOT/hourly.png" "$WEB_ROOT/daily.png" "$WEB_ROOT/monthly.png"
else
  echo "WARN: vnstati not found; skip png generation"
fi
