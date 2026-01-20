#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请用 root 执行：sudo bash uninstall.sh"
  exit 1
fi

systemctl disable --now vnstat-web-update.timer 2>/dev/null || true

rm -f /etc/systemd/system/vnstat-web-update.service
rm -f /etc/systemd/system/vnstat-web-update.timer
systemctl daemon-reload

rm -f /usr/local/bin/vnstat-web-update.sh

rm -f /etc/lighttpd/conf-enabled/vnstat-web-panel.conf
rm -f /etc/lighttpd/conf-available/vnstat-web-panel.conf
systemctl restart lighttpd 2>/dev/null || true

rm -f /etc/vnstat-web.conf

echo "✅ 已卸载（WEB_PATH 目录内容你可自行删除）"
