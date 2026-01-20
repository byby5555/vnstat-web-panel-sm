#!/usr/bin/env bash
set -Eeuo pipefail

# ===== vnstat-web-panel 一键安装（Debian/Ubuntu）=====
# 用法：
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/byby5555/vnstat-web-panel/main/install.sh)
#
# 可选环境变量：
#   PORT=8888
#   IFACE=eth0
#   WEB_PATH=/var/www/html/vnstat
#   REPO_OWNER=byby5555
#   REPO_NAME=vnstat-web-panel
#   REPO_BRANCH=main

CONFIG_FILE="/etc/vnstat-web.conf"

REPO_OWNER_DEFAULT="byby5555"
REPO_NAME_DEFAULT="vnstat-web-panel"
REPO_BRANCH_DEFAULT="main"

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 执行"; exit 1; }
}

is_debian() { [[ -f /etc/debian_version ]]; }

default_iface() {
  local i
  i="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "${i:-}" ]] && echo "$i" || echo "eth0"
}

raw_url() {
  local path="$1"
  local owner="${REPO_OWNER:-$REPO_OWNER_DEFAULT}"
  local name="${REPO_NAME:-$REPO_NAME_DEFAULT}"
  local br="${REPO_BRANCH:-$REPO_BRANCH_DEFAULT}"
  echo "https://raw.githubusercontent.com/${owner}/${name}/${br}/${path}"
}

download() {
  local path="$1" out="$2"
  local url; url="$(raw_url "$path")"
  echo "下载：$url"
  curl -fsSL "$url" -o "$out" || { echo "❌ 下载失败：$url"; exit 1; }
}

ensure_lighttpd_port_once() {
  local port="$1"
  # 只在 /etc/lighttpd/lighttpd.conf 设置端口，避免“重复 server.port”
  if grep -qE '^[[:space:]]*server\.port[[:space:]]*=' /etc/lighttpd/lighttpd.conf; then
    sed -i "s/^[[:space:]]*server\.port[[:space:]]*=.*/server.port = ${port}/" /etc/lighttpd/lighttpd.conf
  else
    echo "server.port = ${port}" >> /etc/lighttpd/lighttpd.conf
  fi

  # 把 conf-enabled/ 里的 server.port 都注释掉，防止重复
  sed -i 's/^[[:space:]]*server\.port[[:space:]]*=/# server.port =/g' /etc/lighttpd/conf-enabled/*.conf 2>/dev/null || true
}

setup_lighttpd_alias_only() {
  local web_path="$1"

  # 我们的模块只负责 alias，不写 port、不写 cgi
  cat >/etc/lighttpd/conf-available/vnstat-web-panel.conf <<EOF
# vnstat-web-panel (alias only)
alias.url += ( "/vnstat/" => "${web_path}/" )
EOF

  lighty-enable-mod alias >/dev/null 2>&1 || true
  lighty-enable-mod vnstat-web-panel >/dev/null 2>&1 || true

  # 清掉可能导致“Duplicate array-key '/vnstat/'”的旧 alias
  # 做法：只保留 vnstat-web-panel.conf 这一处的 /vnstat/
  for f in /etc/lighttpd/conf-enabled/*.conf; do
    [[ "$f" == "/etc/lighttpd/conf-enabled/vnstat-web-panel.conf" ]] && continue
    sed -i 's/.*alias\.url.*"\/vnstat\/".*/# (disabled duplicate) &/g' "$f" 2>/dev/null || true
  done
}

setup_lighttpd_cgi_safe() {
  # 启用系统 cgi 模块（Debian 默认会通过 10-cgi.conf 提供 /cgi-bin/ 和 cgi.assign）
  lighty-enable-mod cgi >/dev/null 2>&1 || true

  # 禁用 debian-doc（里面常见 cgi.assign = ( "" => "" ) 会导致 lighttpd 解析异常/安全风险）
  lighty-disable-mod debian-doc >/dev/null 2>&1 || true
  rm -f /etc/lighttpd/conf-enabled/90-debian-doc.conf 2>/dev/null || true

  # 把系统 10-cgi.conf 修成“只允许 .cgi”，并确保 /cgi-bin/ 指向 /usr/lib/cgi-bin/
  # 注意：不要直接覆盖 conf-enabled 里的文件（通常是软链），否则会影响 lighty-enable-mod 管理。
  local CGI_AVAIL="/etc/lighttpd/conf-available/10-cgi.conf"
  if [[ -f "$CGI_AVAIL" ]]; then
    # 如果存在 cgi.assign 但不是 .cgi，则替换
    if grep -qE '^[[:space:]]*cgi\.assign[[:space:]]*=' "$CGI_AVAIL"; then
      sed -i 's/^[[:space:]]*cgi\.assign[[:space:]]*=.*/cgi.assign = ( ".cgi" => "" )/g' "$CGI_AVAIL" || true
    else
      # 没有的话追加
      printf '\n$HTTP["url"] =~ "^/cgi-bin/" {\n  cgi.assign = ( ".cgi" => "" )\n}\n' >>"$CGI_AVAIL"
    fi

    # 确保有 /cgi-bin/ alias；如果文件里没有，就追加到同一个 url 匹配块里
    if ! grep -qE 'alias\.url[[:space:]]*\+?=.*"/cgi-bin/"' "$CGI_AVAIL"; then
      printf '\n$HTTP["url"] =~ "^/cgi-bin/" {\n  alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )\n}\n' >>"$CGI_AVAIL"
    fi
  else
    # 极端情况：10-cgi.conf 不存在，就创建我们自己的模块
    cat >/etc/lighttpd/conf-available/vnstat-web-panel-cgi.conf <<'EOF'
server.modules += ( "mod_cgi" )
$HTTP["url"] =~ "^/cgi-bin/" {
  cgi.assign = ( ".cgi" => "" )
  alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )
}
EOF
    lighty-enable-mod vnstat-web-panel-cgi >/dev/null 2>&1 || true
  fi
}

main() {
  need_root
  is_debian || { echo "仅支持 Debian/Ubuntu"; exit 1; }

  local IFACE="${IFACE:-$(default_iface)}"
  local WEB_PATH="${WEB_PATH:-/var/www/html/vnstat}"

  # 端口：支持交互输入（默认 8888），也支持通过环境变量 PORT 直接指定
  local PORT_DEFAULT="8888"
  local PORT_INPUT="${PORT:-}"
  if [[ -z "${PORT_INPUT}" && -t 0 ]]; then
    read -r -p "请输入面板端口 [${PORT_DEFAULT}]：" PORT_INPUT || true
  fi
  PORT_INPUT="${PORT_INPUT:-$PORT_DEFAULT}"
  if [[ ! "$PORT_INPUT" =~ ^[0-9]+$ ]] || (( PORT_INPUT < 1 || PORT_INPUT > 65535 )); then
    echo "⚠️ 端口无效：${PORT_INPUT}，将使用默认端口 ${PORT_DEFAULT}"
    PORT_INPUT="$PORT_DEFAULT"
  fi
  local PORT="$PORT_INPUT"

  # 写配置（给 update.sh 用）
  cat >"$CONFIG_FILE" <<EOF
IFACE=${IFACE}
WEB_PATH=${WEB_PATH}
PORT=${PORT}
EOF
  echo "写入配置：$CONFIG_FILE"

  apt-get update -y
  apt-get install -y ca-certificates curl lighttpd vnstat vnstati >/dev/null

  systemctl enable --now vnstat 2>/dev/null || true

  mkdir -p "$WEB_PATH" /etc/vnstat-web
  chown -R www-data:www-data "$WEB_PATH" /etc/vnstat-web
  chmod 750 /etc/vnstat-web

  # 阈值默认配置（CGI 写它）
  if [[ ! -f /etc/vnstat-web/quota.json ]]; then
    echo '{"quota_gb":1024,"alert_pct":90,"danger_pct":100}' > /etc/vnstat-web/quota.json
  fi
  chown www-data:www-data /etc/vnstat-web/quota.json
  chmod 640 /etc/vnstat-web/quota.json

  # 下载文件到临时目录
  local TMP_DIR=""
  TMP_DIR="$(mktemp -d /tmp/vnstat-web-panel.XXXXXX)" || { echo "❌ mktemp 失败"; exit 1; }
  trap '[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"' EXIT

  download "scripts/vnstat-web-update.sh" "$TMP_DIR/vnstat-web-update.sh"
  download "web/index.html"              "$TMP_DIR/index.html"
  download "systemd/vnstat-web-update.service" "$TMP_DIR/vnstat-web-update.service"
  download "systemd/vnstat-web-update.timer"   "$TMP_DIR/vnstat-web-update.timer"
  download "cgi-bin/vnstat-web-config.cgi"     "$TMP_DIR/vnstat-web-config.cgi"

  # 安装文件
  install -m 755 "$TMP_DIR/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh
  install -m 644 "$TMP_DIR/index.html" "$WEB_PATH/index.html"
  install -m 755 "$TMP_DIR/vnstat-web-config.cgi" /usr/lib/cgi-bin/vnstat-web-config.cgi

  install -m 644 "$TMP_DIR/vnstat-web-update.service" /etc/systemd/system/vnstat-web-update.service
  install -m 644 "$TMP_DIR/vnstat-web-update.timer"   /etc/systemd/system/vnstat-web-update.timer

  # lighttpd：端口只在主配置；alias-only 模块；cgi 用系统安全版
  ensure_lighttpd_port_once "$PORT"
  setup_lighttpd_alias_only "$WEB_PATH"
  setup_lighttpd_cgi_safe

  systemctl daemon-reload
  systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true

  # 检查并启动
  lighttpd -tt -f /etc/lighttpd/lighttpd.conf
  systemctl restart lighttpd

  # 生成一次数据
  /usr/local/bin/vnstat-web-update.sh >/dev/null 2>&1 || true

  echo
  echo "✅ 安装完成"
  echo "- 网卡：$IFACE"
  echo "- Web： http://<你的服务器IP>:${PORT}/vnstat/"
  echo "- CGI： http://<你的服务器IP>:${PORT}/cgi-bin/vnstat-web-config.cgi"
  echo
  echo "常用命令："
  echo "- 手动更新：sudo /usr/local/bin/vnstat-web-update.sh"
  echo "- 看 lighttpd：systemctl status lighttpd --no-pager"
  echo "- 看日志：journalctl -u lighttpd -n 80 --no-pager"
}

main "$@"
