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

CFG="/etc/vnstat-web.conf"
if [[ ! -f "$CFG" ]]; then
  cat >"$CFG" <<'EOF'
quota_gb=1024
alert_pct=90
danger_pct=100
EOF
fi
ok "写入配置：$CFG"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates vnstat lighttpd

# 固定默认仓库（可覆盖）
REPO="${GITHUB_REPO:-byby5555/vnstat-web-panel-sm}"
BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
log "使用资源地址：$RAW_BASE"

TMP_DIR="$(mktemp -d /tmp/vnstat-web-panel.XXXXXX)"
cleanup(){ rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT
cd "$TMP_DIR"

download_required() {
  local url="$1" out="$2" mode="${3:-}"
  if ! curl -fsSL "$url" -o "$out"; then
    die "下载失败：$url"
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$out" || true
}

download_optional() {
  local url="$1" out="$2" mode="${3:-}"
  curl -fsSL "$url" -o "$out" >/dev/null 2>&1 || true
  [[ -s "$out" && -n "$mode" ]] && chmod "$mode" "$out" || true
  return 0
}

mkdir -p web cgi-bin scripts systemd

# 必需文件
download_required "$RAW_BASE/web/index.html" "web/index.html" 644
download_required "$RAW_BASE/cgi-bin/vnstat-web-config.cgi" "cgi-bin/vnstat-web-config.cgi" 755
download_required "$RAW_BASE/scripts/vnstat-web-update.sh" "scripts/vnstat-web-update.sh" 755

# 可选
download_optional "$RAW_BASE/scripts/vnstat-quota-check.sh" "scripts/vnstat-quota-check.sh" 755
download_optional "$RAW_BASE/systemd/vnstat-web-update.service" "systemd/vnstat-web-update.service" 644
download_optional "$RAW_BASE/systemd/vnstat-web-update.timer"   "systemd/vnstat-web-update.timer" 644
download_optional "$RAW_BASE/systemd/vnstat-quota-check.service" "systemd/vnstat-quota-check.service" 644
download_optional "$RAW_BASE/systemd/vnstat-quota-check.timer"   "systemd/vnstat-quota-check.timer" 644

# 安装 web
rm -rf /var/www/vnstat-web
mkdir -p /var/www/vnstat-web
cp -a web/. /var/www/vnstat-web/

# 安装 CGI
install -m 755 cgi-bin/vnstat-web-config.cgi /usr/lib/cgi-bin/vnstat-web-config.cgi

# 安装脚本
mkdir -p /usr/local/bin
install -m 755 scripts/vnstat-web-update.sh /usr/local/bin/vnstat-web-update.sh
[[ -f scripts/vnstat-quota-check.sh ]] && install -m 755 scripts/vnstat-quota-check.sh /usr/local/bin/vnstat-quota-check.sh || true

# systemd（可选）
if compgen -G "systemd/*.service" >/dev/null || compgen -G "systemd/*.timer" >/dev/null; then
  cp -a systemd/. /etc/systemd/system/ || true
  systemctl daemon-reload || true
  for t in /etc/systemd/system/*.timer; do
    [[ -f "$t" ]] || continue
    systemctl enable --now "$(basename "$t")" >/dev/null 2>&1 || true
  done
fi

# ========== 关键：清理遗留的自定义 CGI conf，避免重复 cgi.assign ==========
# 你的日志显示现在确实启用了它（或者之前启用过）
rm -f /etc/lighttpd/conf-enabled/10-cgi-vnstat.conf || true
rm -f /etc/lighttpd/conf-available/10-cgi-vnstat.conf || true

# 只启用 Debian 自带 CGI 模块（它会提供 /cgi-bin/ 的 cgi.assign）
lighty-enable-mod cgi >/dev/null 2>&1 || true
lighty-disable-mod debian-doc >/dev/null 2>&1 || true

# 我们自己的 conf：不写 cgi.assign，避免和 /etc/lighttpd/conf-enabled/10-cgi.conf 冲突
CONF_AVAIL="/etc/lighttpd/conf-available/99-vnstat-web.conf"
CONF_ENAB="/etc/lighttpd/conf-enabled/99-vnstat-web.conf"

cat >"$CONF_AVAIL" <<EOF
# vnstat web panel (safe): no server.port, no cgi.assign
\$SERVER["socket"] == ":${PORT}" {
  server.document-root = "/var/www/vnstat-web"
  index-file.names = ( "index.html" )
  alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )
}
EOF

sed -i 's/\r$//' "$CONF_AVAIL"
ln -sf ../conf-available/99-vnstat-web.conf "$CONF_ENAB"

# 验证与重启
lighttpd -tt -f /etc/lighttpd/lighttpd.conf || die "lighttpd 配置检测失败：journalctl -u lighttpd -n 120 --no-pager"
systemctl enable --now vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

ok "安装完成"
echo "访问：http://<你的IP>:${PORT}/"
echo "测试 CGI：curl -i http://127.0.0.1:${PORT}/cgi-bin/vnstat-web-config.cgi"
