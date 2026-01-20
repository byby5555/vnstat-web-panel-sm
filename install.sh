#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*" >&2; }
die(){ err "$*"; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：sudo bash install.sh"

DEFAULT_PORT="8888"
read -r -p "请输入面板端口 [${DEFAULT_PORT}]：" PORT || true
PORT="${PORT:-$DEFAULT_PORT}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "端口必须是数字"
(( PORT >= 1 && PORT <= 65535 )) || die "端口范围必须在 1-65535"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates vnstat lighttpd

# 默认仓库（可用环境变量覆盖）
REPO="${GITHUB_REPO:-byby5555/vnstat-web-panel-sm}"
BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
log "使用资源地址：$RAW_BASE"

# 写入配置（可按需扩展）
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

# 1) 下载整个仓库源码（避免漏 web/assets 等资源）
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

# 2) 安装 web（整目录）
[[ -d "${SRC_DIR}/web" ]] || die "源码包中缺少 web/ 目录"
rm -rf /var/www/vnstat-web
mkdir -p /var/www/vnstat-web
cp -a "${SRC_DIR}/web/." /var/www/vnstat-web/

# 3) 安装 CGI
[[ -f "${SRC_DIR}/cgi-bin/vnstat-web-config.cgi" ]] || die "缺少 cgi-bin/vnstat-web-config.cgi"
install -m 755 "${SRC_DIR}/cgi-bin/vnstat-web-config.cgi" /usr/lib/cgi-bin/vnstat-web-config.cgi

# 4) 安装更新脚本（生成 vnstat.json / summary.txt / server_time.json / hourly.png 等）
[[ -f "${SRC_DIR}/scripts/vnstat-web-update.sh" ]] || die "缺少 scripts/vnstat-web-update.sh"
mkdir -p /usr/local/bin
install -m 755 "${SRC_DIR}/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh

# 5) 安装 systemd（如果仓库提供）
if [[ -d "${SRC_DIR}/systemd" ]]; then
  cp -a "${SRC_DIR}/systemd/." /etc/systemd/system/ 2>/dev/null || true
  systemctl daemon-reload || true
fi

# 6) lighttpd：只用系统自带 CGI 模块，避免 cgi.assign 重复
rm -f /etc/lighttpd/conf-enabled/10-cgi-vnstat.conf /etc/lighttpd/conf-available/10-cgi-vnstat.conf || true
lighty-enable-mod cgi >/dev/null 2>&1 || true
lighty-disable-mod debian-doc >/dev/null 2>&1 || true

# 7) 写入面板 socket 配置（不写 server.port，不写 cgi.assign）
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

# 8) 首次生成数据文件：失败就退出（不要吞错）
chmod +x /usr/local/bin/vnstat-web-update.sh || true
sed -i 's/\r$//' /usr/local/bin/vnstat-web-update.sh || true

log "首次生成数据文件（vnstat.json/summary.txt/server_time.json/PNG）..."
if /usr/local/bin/vnstat-web-update.sh; then
  ok "首次生成完成"
else
  err "首次生成失败：请执行 sudo bash -x /usr/local/bin/vnstat-web-update.sh 查看原因"
  exit 1
fi

# 再跑一次更稳（刚装 vnstat 时图更容易立刻有）
sleep 1
/usr/local/bin/vnstat-web-update.sh || true

# 9) 启用 timer（如果存在）
if [[ -f /etc/systemd/system/vnstat-web-update.timer ]]; then
  systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true
fi

# 10) 校验 & 重启
lighttpd -tt -f /etc/lighttpd/lighttpd.conf || die "lighttpd 配置检测失败：journalctl -u lighttpd -n 120 --no-pager"
systemctl enable --now vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

ok "安装完成"
echo "访问：http://<你的IP>:${PORT}/"
echo "手动更新：sudo /usr/local/bin/vnstat-web-update.sh"

echo
echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in /server_time.json /summary.txt /vnstat.json /vnstat_5min.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${u}" || true)"
  echo "${code}  ${u}"
done
