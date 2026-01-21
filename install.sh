#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*" >&2; }
die(){ err "$*"; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：su - 后再执行，或使用 root 用户"

DEFAULT_PORT="8888"
read -r -p "请输入面板端口 [${DEFAULT_PORT}]：" PORT || true
PORT="${PORT:-$DEFAULT_PORT}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "端口必须是数字"
(( PORT >= 1 && PORT <= 65535 )) || die "端口范围必须在 1-65535"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "安装依赖..."
apt-get update -y
apt-get install -y vnstat lighttpd curl jq

log "创建 Web 目录..."
mkdir -p /var/www/vnstat-web
cp -a "$BASE_DIR/web/." /var/www/vnstat-web/

log "安装 lighttpd 配置..."
cp -a "$BASE_DIR/lighttpd/vnstat-web.conf" /etc/lighttpd/conf-available/99-vnstat-web.conf
ln -sf /etc/lighttpd/conf-available/99-vnstat-web.conf /etc/lighttpd/conf-enabled/99-vnstat-web.conf

# === 新增：启用 /vnstat/ alias（与你当前 VPS 一致） ===
if [ -f "$BASE_DIR/lighttpd/50-vnstat-alias.conf" ]; then
  install -m 644 "$BASE_DIR/lighttpd/50-vnstat-alias.conf" \
    /etc/lighttpd/conf-available/50-vnstat-alias.conf
  ln -sf /etc/lighttpd/conf-available/50-vnstat-alias.conf \
    /etc/lighttpd/conf-enabled/50-vnstat-alias.conf
fi

log "配置 lighttpd 端口..."
sed -i "s/^server.port *= *.*/server.port = ${PORT}/" /etc/lighttpd/lighttpd.conf

log "重启 lighttpd..."
systemctl restart lighttpd

log "安装 vnstat-web-update..."
install -m 755 "$BASE_DIR/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh

log "安装 systemd 单元..."
cp -a "$BASE_DIR/systemd/"* /etc/systemd/system/
systemctl daemon-reload

if systemctl enable --now vnstat-web-update.timer; then
  ok "vnstat-web-update 定时器已启用"
else
  err "未找到 vnstat-web-update.timer（无法自动刷新）"
fi

ok "安装完成"
echo
echo "访问：http://<你的IP>:${PORT}/vnstat/"
echo "手动更新：/usr/local/bin/vnstat-web-update.sh（需 root）"
echo "查看定时器：systemctl list-timers vnstat-web-update.timer"
echo

echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in /server_time.json /summary.txt /vnstat.json /vnstat_5min.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:${PORT}/vnstat${u}" || true)"
  echo "${code}  /vnstat${u}"
done
