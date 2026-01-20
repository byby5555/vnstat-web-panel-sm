#!/bin/sh
set -eu

CONF="/etc/vnstat-web.conf"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || true
fi

# 基本配置
IFACE="${IFACE:-eth0}"
WEB_ROOT="${WEB_ROOT:-/var/www/html/vnstat}"

# 5分钟数据点数：默认 288（24小时）
# 7天=2016，30天=8640，90天=25920（点太多可能页面卡）
FIVE_MIN_POINTS="${FIVE_MIN_POINTS:-288}"

# 额度/阈值/自动关机配置（用于 quota.json 展示 + quota-check 脚本读取）
QUOTA_GB="${QUOTA_GB:-0}"           # 月额度(GB)。0 表示不启用额度显示
ALERT_PCT="${ALERT_PCT:-90}"        # 告警阈值百分比
CUTOFF_PCT="${CUTOFF_PCT:-100}"     # 关机阈值百分比
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-0}" # 0/1 仅展示；真正关机由 quota-check 脚本执行

mkdir -p "$WEB_ROOT"

# ---- 生成 PNG（可选：vnstati 存在才生成）----
if command -v vnstati >/dev/null 2>&1; then
  vnstati -i "$IFACE" -h -o "$WEB_ROOT/hourly.png" || true
  vnstati -i "$IFACE" -d -o "$WEB_ROOT/daily.png"  || true
  vnstati -i "$IFACE" -m -o "$WEB_ROOT/monthly.png" || true
fi

# ---- 摘要（文本）----
vnstat -i "$IFACE" > "$WEB_ROOT/summary_en.txt" || true

# ---- JSON：小时/天/月等汇总 ----
vnstat --json -i "$IFACE" > "$WEB_ROOT/vnstat.json"

# ---- JSON：5分钟 ----
# vnstat 的 “f” 模式输出分钟级条目（常用 5 分钟粒度）
# FIVE_MIN_POINTS 控制输出条目数量
vnstat --json f "$FIVE_MIN_POINTS" -i "$IFACE" > "$WEB_ROOT/vnstat_5min.json"

# ---- summary 简单中文化（失败就用英文）----
if [ -f "$WEB_ROOT/summary_en.txt" ]; then
  sed -e 's/Database updated/数据库更新时间/g' \
      -e 's/ since / 自 /g' \
      -e 's/ rx:/ 下行:/g' \
      -e 's/ tx:/ 上行:/g' \
      -e 's/ total:/ 总计:/g' \
      -e 's/^   monthly/   月度统计/g' \
      -e 's/^   daily/   每日统计/g' \
      -e 's/^     estimated/     预估/g' \
      -e 's/ yesterday/ 昨日/g' \
      -e 's/ today/ 今日/g' \
      -e 's/ avg. rate/ 平均速率/g' \
      "$WEB_ROOT/summary_en.txt" > "$WEB_ROOT/summary.txt" 2>/dev/null \
    || cp "$WEB_ROOT/summary_en.txt" "$WEB_ROOT/summary.txt"
fi

# ---- 生成 quota.json（给网页展示用）----
# 依赖 jq 才能稳定解析 vnstat.json。没有 jq 就生成一个最小的占位 json
cycle="$(date +%Y-%m)"
used_bytes="0"
used_gb="0.00"
pct="0.00"

if command -v jq >/dev/null 2>&1 && [ -f "$WEB_ROOT/vnstat.json" ]; then
  # 取当前月（月度数组最后一条）：rx+tx = total bytes
  used_bytes="$(jq -r '.interfaces[0].traffic.month | last | (.rx + .tx)' "$WEB_ROOT/vnstat.json" 2>/dev/null || echo 0)"
  used_gb="$(awk -v b="$used_bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"

  if [ "$QUOTA_GB" != "0" ] && [ "$QUOTA_GB" != "" ]; then
    pct="$(awk -v u="$used_gb" -v q="$QUOTA_GB" 'BEGIN{ if(q>0) printf "%.2f",(u/q)*100; else print "0.00"}')"
  fi
fi

cat > "$WEB_ROOT/quota.json" <<EOF
{
  "cycle": "$cycle",
  "iface": "$IFACE",
  "quota_gb": $QUOTA_GB,
  "used_gb": $used_gb,
  "percent": $pct,
  "alert_pct": $ALERT_PCT,
  "cutoff_pct": $CUTOFF_PCT,
  "auto_shutdown": $AUTO_SHUTDOWN,
  "five_min_points": $FIVE_MIN_POINTS,
  "updated_at": "$(date -Is)"
}
EOF
# 生成服务器时间/时区信息，供前端展示
TZNAME="$(cat /etc/timezone 2>/dev/null || true)"
[[ -z "${TZNAME:-}" ]] && TZNAME="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[[ -z "${TZNAME:-}" ]] && TZNAME="unknown"

NOW_ISO="$(date -Is)"
OFFSET="$(date +%z)"

cat > "${WEB_PATH}/server_time.json" <<EOF
{"server_time_iso":"${NOW_ISO}","server_tz":"${TZNAME}","server_utc_offset":"${OFFSET}"}
EOF
chmod 644 "${WEB_PATH}/server_time.json" || true

# ---- 权限（Debian/lighttpd 默认 www-data；失败忽略）----
chown -f www-data:www-data \
  "$WEB_ROOT/vnstat.json" \
  "$WEB_ROOT/vnstat_5min.json" \
  "$WEB_ROOT/quota.json" \
  "$WEB_ROOT/summary.txt" \
  "$WEB_ROOT/summary_en.txt" 2>/dev/null || true

# png 可选
chown -f www-data:www-data \
  "$WEB_ROOT/hourly.png" \
  "$WEB_ROOT/daily.png" \
  "$WEB_ROOT/monthly.png" 2>/dev/null || true
