#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT="${WEB_ROOT:-/var/www/vnstat-web}"
VNSTAT_BIN="${VNSTAT_BIN:-vnstat}"

mkdir -p "$WEB_ROOT"

# 生成 vnstat.json（全量）
"$VNSTAT_BIN" --json > "${WEB_ROOT}/vnstat.json"

# 生成 vnstat_5min.json（先复制全量，确保前端不 404；后续要精简再优化）
cp -f "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json"

# 生成 summary.txt（简单汇总）
IFLIST="$("$VNSTAT_BIN" --iflist | sed 's/^Available interfaces: //')"
{
  echo "Interfaces: ${IFLIST}"
  echo "Updated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Source: vnstat --json"
} > "${WEB_ROOT}/summary.txt"

chmod 644 "${WEB_ROOT}/vnstat.json" "${WEB_ROOT}/vnstat_5min.json" "${WEB_ROOT}/summary.txt"
