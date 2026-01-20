#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*" >&2; }
die(){ err "$*"; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：sudo bash uninstall.sh"

PANEL_ROOT="/var/www/vnstat-web"
LIGHTTPD_AVAIL="/etc/lighttpd/conf-available/99-vnstat-web.conf"
LIGHTTPD_ENAB="/etc/lighttpd/conf-enabled/99-vnstat-web.conf"

CGI_CONFIG="/usr/lib/cgi-bin/vnstat-web-config.cgi"
UPDATE_SH="/usr/local/bin/vnstat-web-update.sh"
CFG="/etc/vnstat-web.conf"

SYSTEMD_SVC="/etc/systemd/system/vnstat-web-update.service"
SYSTEMD_TMR="/etc/systemd/system/vnstat-web-update.timer"

log "停止并禁用定时器（如存在）"
systemctl disable --now vnstat-web-update.timer >/dev/null 2>&1 || true
systemctl disable --now vnstat-web-update.service >/dev/null 2>&1 || true

log "删除 systemd 单元文件（如存在）"
rm -f "$SYSTEMD_SVC" "$SYSTEMD_TMR"
systemctl daemon-reload >/dev/null 2>&1 || true

log "删除 lighttpd 面板配置"
rm -f "$LIGHTTPD_ENAB" "$LIGHTTPD_AVAIL"

log "删除 CGI/脚本"
rm -f "$CGI_CONFIG" "$UPDATE_SH"

log "删除面板目录（含 index.html、json、png 等）"
rm -rf "$PANEL_ROOT"

log "删除面板配置文件（如你希望保留可注释这一行）"
rm -f "$CFG"

log "检测 lighttpd 配置并重启"
if command -v lighttpd >/dev/null 2>&1; then
  if lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null 2>&1; then
    systemctl restart lighttpd >/dev/null 2>&1 || true
    ok "lighttpd 已重启"
  else
    err "lighttpd 配置检测失败，请手工检查：journalctl -u lighttpd -n 120 --no-pager"
  fi
fi

ok "卸载完成"
echo "提示：本脚本不会卸载 vnstat/lighttpd 软件包。如需卸载可执行："
echo "  apt-get purge -y vnstat lighttpd && apt-get autoremove -y"
