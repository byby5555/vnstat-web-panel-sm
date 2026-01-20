#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 运行：sudo bash uninstall.sh"; exit 1; }

# 可选：PURGE_PACKAGES=1 会额外 purge vnstat/lighttpd（谨慎）
PURGE_PACKAGES="${PURGE_PACKAGES:-0}"

log "停止并禁用 vnstat-web update timer/service（如果存在）..."
systemctl disable --now vnstat-web-update.timer >/dev/null 2>&1 || true
systemctl disable --now vnstat-web-update.service >/dev/null 2>&1 || true

log "移除 systemd 单元（如果存在）..."
rm -f /etc/systemd/system/vnstat-web-update.timer
rm -f /etc/systemd/system/vnstat-web-update.service
systemctl daemon-reload >/dev/null 2>&1 || true

log "移除 lighttpd 面板配置..."
rm -f /etc/lighttpd/conf-enabled/99-vnstat-web.conf
rm -f /etc/lighttpd/conf-available/99-vnstat-web.conf

# 你之前遇到过 legacy/冲突文件，这里也顺便清理（不影响系统 cgi 模块）
rm -f /etc/lighttpd/conf-enabled/10-cgi-vnstat.conf /etc/lighttpd/conf-available/10-cgi-vnstat.conf || true

log "移除 CGI 与更新脚本..."
rm -f /usr/lib/cgi-bin/vnstat-web-config.cgi
rm -f /usr/local/bin/vnstat-web-update.sh

log "移除 web 目录与配置..."
rm -rf /var/www/vnstat-web
rm -f /etc/vnstat-web.conf

log "重启 lighttpd（如果已安装）..."
if command -v lighttpd >/dev/null 2>&1; then
  systemctl restart lighttpd >/dev/null 2>&1 || true
  ok "lighttpd 已重启"
else
  ok "lighttpd 未安装，跳过重启"
fi

if [[ "$PURGE_PACKAGES" == "1" ]]; then
  log "PURGE_PACKAGES=1：将 purge vnstat 与 lighttpd（谨慎）..."
  apt-get purge -y vnstat lighttpd || true
  apt-get autoremove -y || true
  ok "vnstat/lighttpd 已 purge（如有安装）"
fi

ok "卸载完成"
echo "如需连包一起卸载：PURGE_PACKAGES=1 bash uninstall.sh"
