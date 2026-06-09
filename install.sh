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

detect_web_group(){
  local candidates=(www-data lighttpd http apache nginx)
  local g
  for g in "${candidates[@]}"; do
    if getent group "$g" >/dev/null 2>&1; then
      echo "$g"
      return 0
    fi
  done
  echo "root"
}

repair_lighttpd_main_conf(){
  local conf="/etc/lighttpd/lighttpd.conf" backup
  install -d -m 755 /etc/lighttpd/conf-enabled /etc/lighttpd/conf-available
  if [[ -f "$conf" ]] && lighttpd -tt -f "$conf" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "$conf" ]]; then
    backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$conf" "$backup"
    log "检测到 lighttpd 主配置损坏，已备份到 $backup 并重建最小配置"
  else
    log "未找到 lighttpd 主配置，正在创建最小配置"
  fi

  cat > "$conf" <<'EOF_LIGHTTPD'
server.modules = (
  "mod_indexfile",
  "mod_access",
  "mod_alias",
  "mod_redirect",
  "mod_cgi"
)

server.document-root = "/var/www/html"
server.upload-dirs = ( "/var/cache/lighttpd/uploads" )
server.errorlog = "/var/log/lighttpd/error.log"
server.pid-file = "/run/lighttpd.pid"
server.username = "www-data"
server.groupname = "www-data"
server.port = 8888

index-file.names = ( "index.html" )
url.access-deny = ( "~", ".inc" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi", ".cgi" )

include_shell "/usr/share/lighttpd/use-ipv6.pl " + server.port
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
include "/etc/lighttpd/conf-enabled/*.conf"
EOF_LIGHTTPD
}

gen_strong_password(){
  local raw pass
  raw="$(openssl rand -base64 64 2>/dev/null || head -c 64 /dev/urandom | base64)"
  pass="$(printf "%s" "$raw" | tr -dc "A-Za-z0-9@#%+=_" | cut -c1-20)"
  if [[ ${#pass} -lt 16 ]]; then
    pass="$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d " \n")"
  fi
  echo "$pass"
}

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
TOKEN_FILE="/root/vnstat-web-token.txt"
if [[ -f "$TOKEN_FILE" ]]; then
  QUOTA_TOKEN="$(tr -d ' \n' < "$TOKEN_FILE" | head -n1)"
fi
if [[ -z "${QUOTA_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    QUOTA_TOKEN="$(openssl rand -hex 16)"
  else
    QUOTA_TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  umask 077
  printf "%s\n" "$QUOTA_TOKEN" > "$TOKEN_FILE"
fi

cat > /etc/vnstat-web.conf <<EOF
IFACE=${IFACE_DETECTED:-eth0}
WEB_ROOT=/var/www/vnstat-web
WEB_PATH=/var/www/vnstat-web
PORT=${PORT}
FIVE_MIN_POINTS=288
QUOTA_GB=1024
ALERT_PCT=90
DANGER_PCT=100
AUTO_SHUTDOWN=0
SHUTDOWN_PCT=100
MONTH_START_DAY=1
TG_ENABLED=0
TG_BOT_TOKEN=
TG_CHAT_ID=
QUOTA_TOKEN=${QUOTA_TOKEN}
MAX_WEB_SIZE_MB=100
EOF

log "安装并启用 lighttpd /vnstat/ alias..."
repair_lighttpd_main_conf
if command -v lighty-enable-mod >/dev/null 2>&1; then
  lighty-enable-mod alias redirect cgi >/dev/null 2>&1 || true
fi
# 清理旧配置
rm -f /etc/lighttpd/conf-enabled/50-vnstat-alias.conf /etc/lighttpd/conf-available/50-vnstat-alias.conf
rm -f /etc/lighttpd/conf-enabled/51-vnstat-root-redirect.conf /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf

install -m 644 "$BASE_DIR/lighttpd/50-vnstat-alias.conf" /etc/lighttpd/conf-available/50-vnstat-alias.conf
ln -sf /etc/lighttpd/conf-available/50-vnstat-alias.conf /etc/lighttpd/conf-enabled/50-vnstat-alias.conf

if [[ -f "$BASE_DIR/lighttpd/51-vnstat-root-redirect.conf" ]]; then
  install -m 644 "$BASE_DIR/lighttpd/51-vnstat-root-redirect.conf" /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf
  ln -sf /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf /etc/lighttpd/conf-enabled/51-vnstat-root-redirect.conf
fi

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
lighttpd -tt -f /etc/lighttpd/lighttpd.conf || die "lighttpd 配置检查失败"

log "重启 lighttpd..."
systemctl enable --now lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd || die "lighttpd 启动失败"

log "安装 vnstat-web-update..."
install -m 755 "$BASE_DIR/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh

log "安装 vnstat-quota-check..."
install -m 755 "$BASE_DIR/scripts/vnstat-quota-check.sh" /usr/local/bin/vnstat-quota-check.sh

log "安装认证与安全管理组件..."
install -d -m 755 /usr/local/lib
install -m 755 "$BASE_DIR/scripts/vnstat-web-auth-lib.sh" /usr/local/lib/vnstat-web-auth-lib.sh
install -m 755 "$BASE_DIR/scripts/vnstat-web-admin.sh" /usr/local/bin/vnstat-web-admin.sh
install -m 755 "$BASE_DIR/uninstall.sh" /usr/local/bin/vnstat-web-uninstall.sh
install -d -m 755 /usr/lib/cgi-bin
install -m 755 "$BASE_DIR/cgi-bin/vnstat-web-config.cgi" /usr/lib/cgi-bin/vnstat-web-config.cgi
install -m 755 "$BASE_DIR/cgi-bin/vnstat-web-auth.cgi" /usr/lib/cgi-bin/vnstat-web-auth.cgi
install -m 755 "$BASE_DIR/cgi-bin/vnstat-web-admin.cgi" /usr/lib/cgi-bin/vnstat-web-admin.cgi
install -m 755 "$BASE_DIR/cgi-bin/vnstat-web-data.cgi" /usr/lib/cgi-bin/vnstat-web-data.cgi

log "修复权限和创建必要目录..."
WEB_GROUP="$(detect_web_group)"
# 确保 CGI 脚本权限正确
chmod 755 /usr/lib/cgi-bin/vnstat-web-auth.cgi
chmod 755 /usr/lib/cgi-bin/vnstat-web-data.cgi
chmod 755 /usr/lib/cgi-bin/vnstat-web-config.cgi
chmod 755 /usr/lib/cgi-bin/vnstat-web-admin.cgi

# 确保认证库权限正确
chmod 755 /usr/local/lib/vnstat-web-auth-lib.sh

# 创建和修复认证相关目录
mkdir -p /var/lib/vnstat-web/auth/{sessions,fails}
mkdir -p /etc/vnstat-web
touch /var/log/vnstat-web-auth.log
chown -R root:"$WEB_GROUP" /var/lib/vnstat-web /etc/vnstat-web /var/log/vnstat-web-auth.log
chmod 775 /var/lib/vnstat-web
chmod 2775 /var/lib/vnstat-web/auth
chmod 2775 /var/lib/vnstat-web/auth/sessions
chmod 2775 /var/lib/vnstat-web/auth/fails
chmod 664 /var/log/vnstat-web-auth.log

# 创建和修复认证配置目录
chmod 2775 /etc/vnstat-web

log "创建快捷管理命令: vn"
cat > /usr/local/bin/vn <<'EOS'
#!/usr/bin/env bash
exec /usr/local/bin/vnstat-web-admin.sh "$@"
EOS
chmod 755 /usr/local/bin/vn

log "初始化随机 Web 登录账号..."
AUTH_DIR="/etc/vnstat-web"
mkdir -p "$AUTH_DIR"
LOGIN_USER="vn$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
LOGIN_PASS="$(gen_strong_password)"
AUTH_NOW="$(date -Is)"
AUTH_SALT="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
AUTH_HASH="$(printf '%s%s' "$AUTH_SALT" "$LOGIN_PASS" | sha256sum | awk '{print $1}')"
umask 027
jq -n --arg now "$AUTH_NOW" --arg user "$LOGIN_USER" --arg salt "$AUTH_SALT" --arg hash "$AUTH_HASH" '{users:[{username:$user,salt:$salt,password_hash:$hash,created_at:$now,updated_at:$now}]}' > "$AUTH_DIR/users.json"
printf '{"session_ttl_seconds":43200,"max_login_failures":5}
' > /etc/vnstat-web/auth.json
printf 'username=%s
password=%s
created_at=%s
' "$LOGIN_USER" "$LOGIN_PASS" "$AUTH_NOW" > /root/vnstat-web-login.txt
chmod 600 /root/vnstat-web-login.txt
chown root:"$WEB_GROUP" "$AUTH_DIR/users.json" /etc/vnstat-web/auth.json
chmod 664 "$AUTH_DIR/users.json" /etc/vnstat-web/auth.json


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
SERVER_IPS="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~/^127\./) print $i}' | paste -sd \, - || true)"
SERVER_IPS="${SERVER_IPS:-$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd \, -)}"
echo
echo "阈值设置 Token（用于保存到服务器）：${QUOTA_TOKEN}"
echo "Token 已保存：${TOKEN_FILE}"
echo "Web 登录账号：${LOGIN_USER}"
echo "Web 登录密码：${LOGIN_PASS}"
echo "登录信息文件：/root/vnstat-web-login.txt"
echo "管理菜单命令：vn"
echo
echo "服务器IP：${SERVER_IPS:-请用 ip a 查看}"
echo "面板端口：${PORT}"
echo "访问：http://<服务器IP>:${PORT}/ （跳转到 /vnstat/）"
echo "访问：http://<服务器IP>:${PORT}/vnstat/"
echo

echo "---- 安装后自检（HTTP code 应为 200） ----"
for u in / /vnstat.json /vnstat_5min.json /summary.txt /server_time.json /hourly.png /daily.png /monthly.png; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${u}" || true)"
  echo "${code}  ${u}"
done
