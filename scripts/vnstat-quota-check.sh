#!/bin/sh
set -eu

CONF="/etc/vnstat-web.conf"
QUOTA_CONF="/etc/vnstat-web/quota.json"

[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF" || true

IFACE="${IFACE:-eth0}"
QUOTA_GB="${QUOTA_GB:-0}"
ALERT_PCT="${ALERT_PCT:-90}"
CUTOFF_PCT="${CUTOFF_PCT:-100}"
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-0}"

# 未配置额度就不做任何事
[ "$QUOTA_GB" -gt 0 ] 2>/dev/null || exit 0

# 需要 jq
[ -f "$QUOTA_CONF" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

quota_gb="$(jq -r '.quota_gb // 0' "$QUOTA_CONF" 2>/dev/null || echo 0)"
auto_shutdown="$(jq -r '.auto_shutdown // 0' "$QUOTA_CONF" 2>/dev/null || echo 0)"
shutdown_pct="$(jq -r '.shutdown_pct // 100' "$QUOTA_CONF" 2>/dev/null || echo 100)"

[ "$quota_gb" -gt 0 ] 2>/dev/null || exit 0
[ "$auto_shutdown" = "1" ] || exit 0

used_bytes="$(vnstat --json -i "$IFACE" | jq -r '.interfaces[0].traffic.month | last | (.rx + .tx)' 2>/dev/null || echo 0)"
used_gb="$(awk -v b="$used_bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"
pct="$(awk -v u="$used_gb" -v q="$QUOTA_GB" 'BEGIN{printf "%.2f", (u/q)*100}')"
pct="$(awk -v u="$used_gb" -v q="$quota_gb" 'BEGIN{ if(q>0) printf "%.2f",(u/q)*100; else print "0.00"}')"

log="/var/log/vnstat-quota.log"

if awk -v p="$pct" -v a="$ALERT_PCT" 'BEGIN{exit !(p>=a)}'; then
  echo "$(date -Is) ALERT pct=$pct used_gb=$used_gb quota_gb=$QUOTA_GB" >> "$log" 2>/dev/null || true
fi

if [ "$AUTO_SHUTDOWN" = "1" ] && awk -v p="$pct" -v c="$CUTOFF_PCT" 'BEGIN{exit !(p>=c)}'; then
  echo "$(date -Is) SHUTDOWN pct=$pct used_gb=$used_gb quota_gb=$QUOTA_GB" >> "$log" 2>/dev/null || true
if awk -v p="$pct" -v c="$shutdown_pct" 'BEGIN{exit !(p>=c)}'; then
  echo "$(date -Is) SHUTDOWN pct=$pct used_gb=$used_gb quota_gb=$quota_gb" >> "$log" 2>/dev/null || true
  shutdown -h now "vnstat quota reached: ${pct}%"
fi
scripts/vnstat-web-update.sh
scripts/vnstat-web-update.sh
+3
-3

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
# 额度/阈值配置（用于 quota.json 展示）
QUOTA_GB="${QUOTA_GB:-0}"           # 月额度(GB)。0 表示不启用额度显示
ALERT_PCT="${ALERT_PCT:-90}"        # 告警阈值百分比
CUTOFF_PCT="${CUTOFF_PCT:-100}"     # 关机阈值百分比
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-0}" # 0/1 仅展示；真正关机由 quota-check 脚本执行
CUTOFF_PCT="${CUTOFF_PCT:-100}"     # 阈值百分比
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-0}" # 0/1 仅展示

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
