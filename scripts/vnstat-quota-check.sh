#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/vnstat-web.conf"
QUOTA_CONF="/etc/vnstat-web/quota.json"
STATE_DIR="/var/lib/vnstat-web"
STATE_FILE="${STATE_DIR}/quota-state"
LOG_FILE="/var/log/vnstat-quota.log"

[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF" || true

IFACE="${IFACE:-eth0}"

[ -f "$QUOTA_CONF" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v vnstat >/dev/null 2>&1 || exit 0

quota_gb="$(jq -r '.quota_gb // 0' "$QUOTA_CONF" 2>/dev/null || echo 0)"
alert_pct="$(jq -r '.alert_pct // 90' "$QUOTA_CONF" 2>/dev/null || echo 90)"
danger_pct="$(jq -r '.danger_pct // 100' "$QUOTA_CONF" 2>/dev/null || echo 100)"
auto_shutdown="$(jq -r '.auto_shutdown // 0' "$QUOTA_CONF" 2>/dev/null || echo 0)"
shutdown_pct="$(jq -r '.shutdown_pct // 100' "$QUOTA_CONF" 2>/dev/null || echo 100)"
month_start_day="$(jq -r '.month_start_day // 1' "$QUOTA_CONF" 2>/dev/null || echo 1)"
tg_enabled="$(jq -r '.tg_enabled // 0' "$QUOTA_CONF" 2>/dev/null || echo 0)"
tg_bot_token="$(jq -r '.tg_bot_token // ""' "$QUOTA_CONF" 2>/dev/null || echo "")"
tg_chat_id="$(jq -r '.tg_chat_id // ""' "$QUOTA_CONF" 2>/dev/null || echo "")"

[ "$quota_gb" -gt 0 ] 2>/dev/null || exit 0

month_start_day="${month_start_day:-1}"
if [ "$month_start_day" -lt 1 ] || [ "$month_start_day" -gt 31 ]; then
  month_start_day=1
fi

year="$(date +%Y)"
month="$(date +%m)"
day="$(date +%d)"

if [ "$day" -ge "$month_start_day" ]; then
  start_year="$year"
  start_month="$month"
else
  if [ "$month" -eq 01 ]; then
    start_year="$((year - 1))"
    start_month="12"
  else
    start_year="$year"
    start_month="$(printf "%02d" "$((10#$month - 1))")"
  fi
fi
start_key="$(printf "%d%02d%02d" "$start_year" "$start_month" "$month_start_day")"

used_bytes="$(vnstat --json -i "$IFACE" | jq -r --argjson start "$start_key" '
  (.interfaces[0].traffic.day // .interfaces[0].traffic.days // []) as $days
  | if ($days | length) > 0 then
      ($days
        | map(select((.date.year*10000)+(.date.month*100)+(.date.day) >= $start)
            | ((.rx // .rx_bytes // 0) + (.tx // .tx_bytes // 0)))
        | add // 0)
    else
      (.interfaces[0].traffic.month // .interfaces[0].traffic.months // [] | last | ((.rx // .rx_bytes // 0) + (.tx // .tx_bytes // 0)))
    end' 2>/dev/null || echo 0)"

used_gb="$(awk -v b="$used_bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"
pct="$(awk -v u="$used_gb" -v q="$quota_gb" 'BEGIN{ if(q>0) printf "%.2f",(u/q)*100; else print "0.00"}')"

mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$STATE_FILE" 2>/dev/null || true

last_level="$(grep -E '^level=' "$STATE_FILE" | tail -n1 | cut -d= -f2- || true)"
last_date="$(grep -E '^date=' "$STATE_FILE" | tail -n1 | cut -d= -f2- || true)"
today="$(date +%F)"

send_telegram(){
  local text="$1"
  if [ "$tg_enabled" != "1" ] || [ -z "$tg_bot_token" ] || [ -z "$tg_chat_id" ]; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${tg_bot_token}/sendMessage" \
    -d "chat_id=${tg_chat_id}" \
    -d "text=${text}" >/dev/null 2>&1 || true
}

record_state(){
  local level="$1"
  printf "level=%s\ndate=%s\n" "$level" "$today" > "$STATE_FILE" 2>/dev/null || true
}

if awk -v p="$pct" -v c="$shutdown_pct" 'BEGIN{exit !(p>=c)}'; then
  echo "$(date -Is) SHUTDOWN pct=$pct used_gb=$used_gb quota_gb=$quota_gb start_day=$month_start_day" >> "$LOG_FILE" 2>/dev/null || true
  if [ "$last_level" != "shutdown" ] || [ "$last_date" != "$today" ]; then
    send_telegram "🚨 vnStat 流量超限自动关机：已用 ${used_gb}GB / ${quota_gb}GB（${pct}%），起算日 ${month_start_day} 号。"
    record_state "shutdown"
  fi
  if [ "$auto_shutdown" = "1" ]; then
    shutdown -h now "vnstat quota reached: ${pct}%"
  fi
  exit 0
fi

if awk -v p="$pct" -v d="$danger_pct" 'BEGIN{exit !(p>=d)}'; then
  echo "$(date -Is) DANGER pct=$pct used_gb=$used_gb quota_gb=$quota_gb start_day=$month_start_day" >> "$LOG_FILE" 2>/dev/null || true
  if [ "$last_level" != "danger" ] || [ "$last_date" != "$today" ]; then
    send_telegram "⚠️ vnStat 流量危险：已用 ${used_gb}GB / ${quota_gb}GB（${pct}%），起算日 ${month_start_day} 号。"
    record_state "danger"
  fi
  exit 0
fi

if awk -v p="$pct" -v a="$alert_pct" 'BEGIN{exit !(p>=a)}'; then
  echo "$(date -Is) ALERT pct=$pct used_gb=$used_gb quota_gb=$quota_gb start_day=$month_start_day" >> "$LOG_FILE" 2>/dev/null || true
  if [ "$last_level" != "alert" ] || [ "$last_date" != "$today" ]; then
    send_telegram "🔔 vnStat 流量告警：已用 ${used_gb}GB / ${quota_gb}GB（${pct}%），起算日 ${month_start_day} 号。"
    record_state "alert"
  fi
  exit 0
fi

record_state "ok"
