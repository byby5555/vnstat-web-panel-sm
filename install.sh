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

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates vnstat lighttpd

REPO="${GITHUB_REPO:-byby5555/vnstat-web-panel-sm}"
BRANCH="${GITHUB_BRANCH:-main}"
log "使用仓库：${REPO} 分支：${BRANCH}"

CFG="/etc/vnstat-web.conf"
if [[ ! -f "$CFG" ]]; then
  cat >"$CFG" <<'EOF'
# 可选：指定统计网卡，例如 interface=eth0
# interface=eth0
quota_gb=1024
alert_pct=90
danger_pct=100
EOF
  ok "写入配置：$CFG"
else
  ok "配置已存在：$CFG"
fi

WORK="/tmp/vnstat-web-src.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
log "下载源码包：$TARBALL_URL"
curl -fsSL -L "$TARBALL_URL" -o src.tgz || die "下载源码包失败：$TARBALL_URL"
tar -xzf src.tgz

REPO_NAME="$(echo "$REPO" | awk -F/ '{print $2}')"
SRC_DIR="$(find . -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)"
[[ -n "$SRC_DIR" ]] || die "解压后未找到源码目录"

# 1) web
[[ -d "${SRC_DIR}/web" ]] || die "源码包中缺少 web/ 目录"
rm -rf /var/www/vnstat-web
mkdir -p /var/www/vnstat-web
cp -a "${SRC_DIR}/web/." /var/www/vnstat-web/
ok "已安装 web 到 /var/www/vnstat-web"

# 2) CGI
[[ -f "${SRC_DIR}/cgi-bin/vnstat-web-config.cgi" ]] || die "缺少 cgi-bin/vnstat-web-config.cgi"
install -m 755 "${SRC_DIR}/cgi-bin/vnstat-web-config.cgi" /usr/lib/cgi-bin/vnstat-web-config.cgi
ok "已安装 CGI 到 /usr/lib/cgi-bin/vnstat-web-config.cgi"

# 3) update script
[[ -f "${SRC_DIR}/scripts/vnstat-web-update.sh" ]] || die "缺少 scripts/vnstat-web-update.sh"
mkdir -p /usr/local/bin
install -m 755 "${SRC_DIR}/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh
sed -i 's/\r$//' /usr/local/bin/vnstat-web-update.sh || true
ok "已安装更新脚本到 /usr/local/bin/vnstat-web-update.sh"

# 4) systemd: 必须带 timer/service
if [[ -d "${SRC_DIR}/systemd" ]]; then
  cp -a "${SRC_DIR}/systemd/." /etc/systemd/system/ 2>/dev/null || true
  # 清理 CRLF，避免你刚才那种“Assignment outside of section”
  find /etc/systemd/system -maxdepth 1 -type f -name 'vnstat-web-update.*' -print0 \
    | xargs -0 -r sed -i 's/\r$//' || true
  systemctl daemon-reload || true
  ok "已安装 systemd 单元到 /etc/systemd/system"
else
  err "源码缺少 systemd/ 目录：将无法自动定时刷新"
fi

# 5) lighttpd：启用 CGI 模块，避免重复 cgi.assign
rm -f /etc/lighttpd/conf-enabled/10-cgi-vnstat.conf /etc/lighttpd/conf-available/10-cgi-vnstat.conf || true
lighty-enable-mod cgi >/dev/null 2>&1 || true
lighty-disable-mod debian-doc >/dev/null 2>&1 || true

CONF_AVAIL="/etc/lighttpd/conf-available/99-vnstat-web.conf"
CONF_ENAB="/etc/lighttpd/conf-enabled/99-vnstat-web.conf"

cat >"$CONF_AVAIL" <<EOF
# vnstat web panel (safe)
\$SERVER["socket"] == ":${PORT}" {
  server.document-root = "/var/www/vnstat-web"
  index-file.names = ( "index.html" )
  alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )
}
EOF
sed -i 's/\r$//' "$CONF_AVAIL"
ln -sf ../conf-available/99-vnstat-web.conf "$CONF_ENAB"
ok "已写入 lighttpd 配置：$CONF_AVAIL"

# 6) 校验 lighttpd
lighttpd -tt -f /etc/lighttpd/lighttpd.conf || die "lighttpd 配置检测失败：journalctl -u lighttpd -n 120 --no-pager"

# 7) 启动 vnstat/lighttpd
systemctl enable --now vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd >/dev/null 2>&1 || true

# 8) 首次生成数据（失败就退出，别吞错）
log "首次生成数据文件..."
/usr/local/bin/vnstat-web-update.sh || die "首次生成失败：bash -x /usr/local/bin/vnstat-web-update.sh"
sleep 1
/usr/local/bin/vnstat-web-update.sh || true
ok "首次生成完成"

# 9) 启用定时刷新（关键）
if [[ -f /etc/systemd/system/vnstat-web-update.timer ]]; then
  systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true
  ok "已启用定时刷新：vnstat-web-update.timer"
else
  err "未找到 /etc/systemd/system/vnstat-web-update.timer（无法自动刷新）"
fi

ok "安装完成"
echo "访问：http://<你的IP>:${PORT}/"
echo "手动更新：/usr/local/bin/vnstat-web-update.sh（需 root）"
echo "查看定时器：systemctl list-timers vnstat-web-update.timer"
echo

echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in /server_time.json /summary.txt /vnstat.json /vnstat_5min.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${u}" || true)"
  echo "${code}  ${u}"
done
