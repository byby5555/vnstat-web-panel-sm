#!/usr/bin/env bash
set -Eeuo pipefail

REPO_OWNER="byby5555"
REPO_NAME="vnstat-web-panel-sm"
REPO_BRANCH="main"

log(){ echo -e "[*] $*"; }
ok(){  echo -e "✅ $*"; }
err(){ echo -e "❌ $*"; }
die(){ err "$*"; exit 1; }

# ===== BOOTSTRAP: support `bash <(curl ...)` =====
# When run via process substitution, this script lives under /dev/fd/* and has no web/ scripts/ lighttpd/ next to it.
# In that case, download the repo tarball to a temp dir and re-run from there.
self_path="${BASH_SOURCE[0]:-}"
self_dir="$(cd "$(dirname "$self_path")" 2>/dev/null && pwd || true)"

need_bootstrap=0
if [[ -z "${self_dir:-}" ]]; then need_bootstrap=1; fi
if [[ "${self_dir:-}" == /dev/fd* ]]; then need_bootstrap=1; fi
if [[ "${self_dir:-}" == /proc/self/fd* ]]; then need_bootstrap=1; fi
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
  log "已下载到：$repo_dir"
  exec bash "$repo_dir/install.sh" "$@"
fi
# ===== END BOOTSTRAP =====

# ===== REAL INSTALL (your existing logic continues here) =====
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

# enable /vnstat/ alias
if [ -f "$BASE_DIR/lighttpd/50-vnstat-alias.conf" ]; then
  install -m 644 "$BASE_DIR/lighttpd/50-vnstat-alias.conf" /etc/lighttpd/conf-available/50-vnstat-alias.conf
  ln -sf /etc/lighttpd/conf-available/50-vnstat-alias.conf /etc/lighttpd/conf-enabled/50-vnstat-alias.conf
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

systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true

ok "安装完成"
echo "访问：http://<你的IP>:${PORT}/vnstat/"
echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in /server_time.json /summary.txt /vnstat.json /vnstat_5min.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/vnstat${u}" || true)"
  echo "${code}  /vnstat${u}"
done
