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

# --- raw base (repo/branch configurable) ---
REPO="${GITHUB_REPO:-byby5555/vnstat-web-panel-sm}"
BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
log "使用资源地址：$RAW_BASE"

# --- temp dir ---
TMP_DIR="$(mktemp -d /tmp/vnstat-web-panel.XXXXXX)"
cleanup(){ rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT
cd "$TMP_DIR"

# --- downloader helpers ---
download_required() {
  local url="$1" out="$2" mode="${3:-}"
  if ! curl -fsSL "$url" -o "$out"; then
    die "下载失败：$url"
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$out" || true
}

download_optional_quiet() {
  local url="$1" out="$2" mode="${3:-}"
  if curl -fsSL "$url" -o "$out" >/dev/null 2>&1; then
    [[ -n "$mode" ]] && chmod "$mode" "$out" || true
    return 0
  fi
  return 1
}

# Try primary path, then legacy path
download_optional_with_legacy() {
  local url1="$1" url2="$2" out="$3" mode="${4:-}"
  if download_optional_quiet "$url1" "$out" "$mode"; then
    ok "下载：$url1"
    return 0
  fi
  if download_optional_quiet "$url2" "$out" "$mode"; then
    ok "下载：$url2"
    return 0
  fi
  log "可选文件不存在（已跳过）：$url1 或 $url2"
  return 0
}

mkdir -p web assets cgi-bin scripts systemd lighttpd config

# --- required files ---
download_required "$RAW_BASE/web/index.html" "web/index.html" 644
download_required "$RAW_BASE/cgi-bin/vnstat-web-config.cgi" "cgi-bin/vnstat-web-config.cgi" 755
download_required "$RAW_BASE/scripts/vnstat-web-update.sh" "scripts/vnstat-web-update.sh" 755
download_required "$RAW_BASE/lighttpd/vnstat-web.conf" "lighttpd/vnstat-web.conf" 644

# --- optional files (quiet) ---
download_optional_quiet "$RAW_BASE/scripts/vnstat-quota-check.sh" "scripts/vnstat-quota-check.sh" 755 || true
download_optional_quiet "$RAW_BASE/config/vnstat-web.conf.example" "config/vnstat-web.conf.example" 644 || true

download_optional_quiet "$RAW_BASE/systemd/vnstat-web-update.service" "systemd/vnstat-web-update.service" 644 || true
download_optional_quiet "$RAW_BASE/systemd/vnstat-web-update.timer"   "systemd/vnstat-web-update.timer" 644 || true
download_optional_quiet "$RAW_BASE/systemd/vnstat-quota-check.service" "systemd/vnstat-quota-check.service" 644 || true
download_optional_quiet "$RAW_BASE/systemd/vnstat-quota-check.timer"   "systemd/vnstat-quota-check.timer" 644 || true

# THIS is your legacy file:
download_optional_with_legacy \
  "$RAW_BASE/lighttpd/10-cgi-vnstat.conf" \
  "$RAW_BASE/lighttpd/legacy/10-cgi-vnstat.conf" \
  "lighttpd/10-cgi-vnstat.conf" 644

# --- install web ---
rm -rf /var/www/vnstat-web
mkdir -p /var/www/vnstat-web
cp -a web/. /var/www/vnstat-web/

# --- install cgi ---
install -m 755 cgi-bin/vnstat-web-config.cgi /usr/lib/cgi-bin/vnstat-web-config.cgi

# --- install scripts ---
mkdir -p /usr/local/bin
install -m 755 scripts/vnstat-web-update.sh /usr/local/bin/vnstat-web-update.sh
[[ -f scripts/vnstat-quota-check.sh ]] && install -m 755 scripts/vnstat-quota-check.sh /usr/local/bin/vnstat-quota-check.sh || true

# --- install systemd units (optional) ---
if compgen -G "systemd/*.service" >/dev/null || compgen -G "systemd/*.timer" >/dev/null; then
  cp -a systemd/. /etc/systemd/system/ || true
  systemctl daemon-reload || true
  for t in /etc/systemd/system/*.timer; do
    [[ -f "$t" ]] || continue
    systemctl enable --now "$(basename "$t")" >/dev/null 2>&1 || true
  done
fi

# --- lighttpd: enable cgi module ---
lighty-enable-mod cgi >/dev/null 2>&1 || true
lighty-disable-mod debian-doc >/dev/null 2>&1 || true

# --- write vnstat-web lighttpd conf safely (NO server.port duplicate!) ---
# We DO NOT include server.port in a global scope. Use socket block.
CONF_AVAIL="/etc/lighttpd/conf-available/99-vnstat-web.conf"
CONF_ENAB="/etc/lighttpd/conf-enabled/99-vnstat-web.conf"

# If your repo vnstat-web.conf still contains server.port, we will ignore it and write our own safe conf.
cat >"$CONF_AVAIL" <<EOF
# vnstat web panel on separate socket - safe include (no duplicate server.port)
\$SERVER["socket"] == ":${PORT}" {
  server.document-root = "/var/www/vnstat-web"
  index-file.names = ( "index.html" )

  alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )

  \$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( ".cgi" => "" )
  }
}
EOF
# remove possible CRLF
sed -i 's/\r$//' "$CONF_AVAIL"
ln -sf ../conf-available/99-vnstat-web.conf "$CONF_ENAB"

# also drop optional 10-cgi-vnstat.conf if downloaded (non-fatal)
if [[ -f "lighttpd/10-cgi-vnstat.conf" ]]; then
  install -m 644 "lighttpd/10-cgi-vnstat.conf" /etc/lighttpd/conf-available/10-cgi-vnstat.conf
  sed -i 's/\r$//' /etc/lighttpd/conf-available/10-cgi-vnstat.conf
  ln -sf ../conf-available/10-cgi-vnstat.conf /etc/lighttpd/conf-enabled/10-cgi-vnstat.conf
fi

# validate and restart
if ! lighttpd -tt -f /etc/lighttpd/lighttpd.conf; then
  die "lighttpd 配置检测失败：请执行 journalctl -u lighttpd -n 120 --no-pager 查看原因"
fi

systemctl enable --now vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

ok "安装完成"
echo "访问：http://<你的IP>:${PORT}/"
echo "测试 CGI：curl -i http://127.0.0.1:${PORT}/cgi-bin/vnstat-web-config.cgi"
