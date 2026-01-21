#!/usr/bin/env bash
set -Eeuo pipefail

REPO_OWNER="byby5555"
REPO_NAME="vnstat-web-panel-sm"
REPO_BRANCH="main"

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*" >&2; }
die(){ err "$*"; exit 1; }

# ===== BOOTSTRAP: support `bash <(curl ...)` =====
self_path="${BASH_SOURCE[0]:-}"
self_dir="$(cd "$(dirname "$self_path")" 2>/dev/null && pwd || true)"

need_bootstrap=0
if [[ -z "${self_dir:-}" ]]; then need_bootstrap=1; fi
if [[ "${self_dir:-}" == /dev/fd* ]] || [[ "${self_dir:-}" == /proc/self/fd* ]]; then need_bootstrap=1; fi
if [[ ! -d "${self_dir:-}/web" ]] || [[ ! -d "${self_dir:-}/scripts" ]] || [[ ! -d "${self_dir:-}/lighttpd" ]]; then
  need_bootstrap=1
fi

if [[ "$need_bootstrap" == "1" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"
  log "检测到 curl 方式运行，正在下载仓库文件到临时目录..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar >/dev/null 2>&1 || true
  curl -fsSL "$url" -o "$tmp/repo.tgz" || die "下载仓库失败：$url"
  tar -xzf "$tmp/repo.tgz" -C "$tmp" || die "解压仓库失败"
  repo_dir="$(find "$tmp" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)"
  [[ -n "${repo_dir:-}" ]] || die "未找到解压后的仓库目录"
  exec bash "$repo_dir/install.sh" "$@"
fi
# ===== END BOOTSTRAP =====

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行（sudo / root 用户）"

DEFAULT_PORT="8888"
read -r -p "请输入面板端口 [${DEFAULT_PORT}]：" PORT || true
PORT="${PORT:-$DEFAULT_PORT}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "端口必须是数字"
(( PORT >= 1 && PORT <= 65535 )) || die "端口范围必须在 1-65535"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "安装依赖..."
apt-get update -y
apt-get install -y vnstat vnstati lighttpd curl jq

log "创建 Web 目录..."
mkdir -p /var/www/vnstat-web
cp -a "$BASE_DIR/web/." /var/www/vnstat-web/

log "写入配置 /etc/vnstat-web.conf..."
detect_iface() {
  local dev=""
  if command -v ip >/dev/null 2>&1; then
    dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  if [[ -n "${dev:-}" && "$dev" != "lo" ]]; then
    echo "$dev"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|virbr|wg|tun|tap)' | head -n 1 && return 0
  fi
  return 1
}

IFACE_DETECTED="$(detect_iface || true)"
cat > /etc/vnstat-web.conf <<EOF
IFACE=${IFACE_DETECTED:-eth0}
WEB_ROOT=/var/www/vnstat-web
WEB_PATH=/var/www/vnstat-web
PORT=${PORT}
FIVE_MIN_POINTS=288
QUOTA_GB=1024
ALERT_PCT=90
DANGER_PCT=100
EOF

log "安装并启用 lighttpd /vnstat/ alias..."
# 只使用 alias 方案：不再安装 99-vnstat-web.conf（避免冲突/改 document-root）
install -m 644 "$BASE_DIR/lighttpd/50-vnstat-alias.conf" /etc/lighttpd/conf-available/50-vnstat-alias.conf
ln -sf /etc/lighttpd/conf-available/50-vnstat-alias.conf /etc/lighttpd/conf-enabled/50-vnstat-alias.conf
install -m 644 "$BASE_DIR/lighttpd/51-vnstat-root-redirect.conf" /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf
ln -sf /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf /etc/lighttpd/conf-enabled/51-vnstat-root-redirect.conf

# （可选）nocache 配置：存在就启用，不存在就跳过
if [[ -f "$BASE_DIR/lighttpd/98-vnstat-web-nocache.conf" ]]; then
  install -m 644 "$BASE_DIR/lighttpd/98-vnstat-web-nocache.conf" /etc/lighttpd/conf-available/98-vnstat-web-nocache.conf
  ln -sf /etc/lighttpd/conf-available/98-vnstat-web-nocache.conf /etc/lighttpd/conf-enabled/98-vnstat-web-nocache.conf
fi

log "配置 lighttpd 端口..."
# 如果有 server.port 就替换；没有就追加
if grep -qE '^\s*server\.port\s*=' /etc/lighttpd/lighttpd.conf; then
  sed -i "s/^\s*server\.port\s*=.*/server.port = ${PORT}/" /etc/lighttpd/lighttpd.conf
else
  echo "server.port = ${PORT}" >> /etc/lighttpd/lighttpd.conf
fi

log "语法检查..."
lighttpd -tt -f /etc/lighttpd/lighttpd.conf

log "重启 lighttpd..."
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

log "安装 vnstat-web-update..."
install -m 755 "$BASE_DIR/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh

log "生成初始数据文件..."
if /usr/local/bin/vnstat-web-update.sh; then
  ok "初始数据文件已生成"
else
  err "初始数据生成失败（请检查 vnstat 服务和接口配置）"
fi

log "安装 systemd 单元..."
if [[ -d "$BASE_DIR/systemd" ]]; then
  cp -a "$BASE_DIR/systemd/"* /etc/systemd/system/ || true
  systemctl daemon-reload
  systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true
fi

ok "安装完成"
echo
echo "访问：http://<你的IP>:${PORT}/ （跳转到 /vnstat/）或 http://<你的IP>:${PORT}/vnstat/"
echo

echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in / /vnstat.json /vnstat_5min.json /summary.txt /server_time.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/vnstat${u}" || true)"
  echo "${code}  /vnstat${u}"
done
