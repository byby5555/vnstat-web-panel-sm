#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# vnstat-web-panel install
# =========================

# ---------- helpers ----------
log() { echo -e "[*] $*"; }
ok()  { echo -e "✅ $*"; }
err() { echo -e "❌ $*" >&2; }
die() { err "$*"; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行（sudo bash install.sh 或 sudo -i 后运行）"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Safe cleanup with set -u
TMP_DIR=""
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "${TMP_DIR:-}" || true
  fi
}
trap cleanup EXIT

# ---------- detect repo / raw base ----------
# Priority:
# 1) From environment GITHUB_RAW_BASE
# 2) From env GITHUB_REPO + GITHUB_BRANCH
# 3) From installer URL if passed as INSTALL_SH_URL
detect_raw_base() {
  if [[ -n "${GITHUB_RAW_BASE:-}" ]]; then
    echo "${GITHUB_RAW_BASE%/}"
    return
  fi

  if [[ -n "${GITHUB_REPO:-}" ]]; then
    local branch="${GITHUB_BRANCH:-main}"
    echo "https://raw.githubusercontent.com/${GITHUB_REPO}/${branch}"
    return
  fi

  # If you run like: INSTALL_SH_URL="https://raw.githubusercontent.com/xxx/yyy/main/install.sh" bash install.sh
  if [[ -n "${INSTALL_SH_URL:-}" ]]; then
    # extract https://raw.githubusercontent.com/<owner>/<repo>/<branch>
    # shellcheck disable=SC2001
    echo "${INSTALL_SH_URL%/install.sh}"
    return
  fi

  # Fallback (keeps compatibility but avoid 404 by telling user how to override)
  echo ""
}

download() {
  local url="$1"
  local out="$2"
  local mode="${3:-}"

  if ! curl -fsSL "$url" -o "$out"; then
    err "下载失败：$url"
    err "你可以这样指定仓库后重试："
    err "  GITHUB_REPO=byby5555/vnstat-web-panel-sm GITHUB_BRANCH=main bash <(curl -fsSL https://raw.githubusercontent.com/byby5555/vnstat-web-panel-sm/main/install.sh)"
    return 1
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$out" || true
  return 0
}

# ---------- settings ----------
DEFAULT_PORT="8888"

prompt_port() {
  local p
  read -r -p "请输入面板端口 [${DEFAULT_PORT}]：" p || true
  p="${p:-$DEFAULT_PORT}"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || die "端口必须是数字"
  (( p >= 1 && p <= 65535 )) || die "端口范围必须在 1-65535"
  echo "$p"
}

# ---------- install deps ----------
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    curl ca-certificates \
    vnstat \
    lighttpd
}

# ---------- lighttpd configure ----------
ensure_lighttpd_cgi() {
  # enable cgi module
  if command_exists lighty-enable-mod; then
    lighty-enable-mod cgi >/dev/null 2>&1 || true
    # debian-doc module can cause weird cgi.assign behavior in some distros; disable if exists
    lighty-disable-mod debian-doc >/dev/null 2>&1 || true
  fi

  # ensure default cgi conf available is sane (do NOT overwrite conf-enabled symlinks)
  local cgi_avail="/etc/lighttpd/conf-available/10-cgi.conf"
  if [[ -f "$cgi_avail" ]]; then
    # Keep existing, but we can ensure it has cgi.module loaded by enabling mod above.
    :
  fi
}

install_lighttpd_vhost() {
  local port="$1"
  local src="$2" # lighttpd/vnstat-web.conf from repo
  local dst="/etc/lighttpd/conf-available/99-vnstat-web.conf"
  install -m 644 "$src" "$dst"

  # Replace port line if present; else append
  if grep -qE '^\s*server\.port\s*=' "$dst"; then
    sed -i "s/^\s*server\.port\s*=.*/server.port = ${port}/" "$dst"
  else
    echo "server.port = ${port}" >> "$dst"
  fi

  if command_exists lighty-enable-mod; then
    lighty-enable-mod vnstat-web >/dev/null 2>&1 || true
  fi

  # If lighty-enable-mod doesn't manage custom conf, create symlink ourselves
  if [[ ! -e "/etc/lighttpd/conf-enabled/99-vnstat-web.conf" ]]; then
    ln -sf "../conf-available/99-vnstat-web.conf" "/etc/lighttpd/conf-enabled/99-vnstat-web.conf"
  fi
}

# ---------- file install ----------
install_web_files() {
  local src_web="$1"  # repo web/
  local dst_web="/var/www/vnstat-web"
  rm -rf "$dst_web"
  mkdir -p "$dst_web"
  cp -a "${src_web}/." "$dst_web/"
}

install_cgi() {
  local src_cgi="$1" # repo cgi-bin/vnstat-web-config.cgi
  local dst="/usr/lib/cgi-bin/vnstat-web-config.cgi"
  install -m 755 "$src_cgi" "$dst"
}

install_scripts() {
  local src_scripts="$1" # repo scripts/
  mkdir -p /usr/local/bin
  if [[ -d "$src_scripts" ]]; then
    for f in "$src_scripts"/*; do
      [[ -f "$f" ]] || continue
      install -m 755 "$f" "/usr/local/bin/$(basename "$f")"
    done
  fi
}

install_systemd_units() {
  local src="$1" # repo systemd/
  if [[ -d "$src" ]]; then
    cp -a "$src/." /etc/systemd/system/
    systemctl daemon-reload
    # enable timers if exist (non-fatal)
    for t in /etc/systemd/system/*.timer; do
      [[ -f "$t" ]] || continue
      systemctl enable --now "$(basename "$t")" >/dev/null 2>&1 || true
    done
  fi
}

write_config() {
  # You之前日志显示写入 /etc/vnstat-web.conf，所以保持兼容
  local cfg="/etc/vnstat-web.conf"
  if [[ ! -f "$cfg" ]]; then
    cat > "$cfg" <<'EOF'
# vnstat-web-panel config
# quota_gb: monthly quota in GB
# alert_pct/danger_pct: percentage thresholds
quota_gb=1024
alert_pct=90
danger_pct=100
EOF
  fi
  ok "写入配置：$cfg"
}

restart_services() {
  systemctl enable --now vnstat >/dev/null 2>&1 || true
  systemctl restart vnstat >/dev/null 2>&1 || true
  systemctl enable --now lighttpd >/dev/null 2>&1 || true
  systemctl restart lighttpd
}

# ---------- main ----------
main() {
  need_root

  local port
  port="$(prompt_port)"

  write_config

  apt_install
  ensure_lighttpd_cgi

  # Work directory
  TMP_DIR="$(mktemp -d /tmp/vnstat-web-panel.XXXXXX)"
  cd "$TMP_DIR"

  # Determine raw base
  local RAW_BASE
  RAW_BASE="$(detect_raw_base)"
  if [[ -z "$RAW_BASE" ]]; then
    die "无法自动确定仓库 Raw 地址。请用环境变量指定：GITHUB_REPO=owner/repo （可选 GITHUB_BRANCH=main）"
  fi
  log "使用资源地址：$RAW_BASE"

  # Download required files to build a local tree
  mkdir -p web/assets cgi-bin scripts systemd lighttpd config

  # Minimal web (if you keep more assets, add more downloads or switch to tarball release later)
  # If you already have full web directory in repo, you should prefer tarball mode. Here we fetch key files.
  # Try to download manifest-like files; non-existing optional files won't break.
  download "$RAW_BASE/web/index.html" "web/index.html" 644 || die "web/index.html 不存在或无法下载"
  curl -fsSL "$RAW_BASE/web/assets/" >/dev/null 2>&1 || true

  # CGI
  download "$RAW_BASE/cgi-bin/vnstat-web-config.cgi" "cgi-bin/vnstat-web-config.cgi" 755 || die "cgi-bin/vnstat-web-config.cgi 不存在或无法下载"

  # scripts (required: vnstat-web-update.sh; others optional)
  download "$RAW_BASE/scripts/vnstat-web-update.sh" "scripts/vnstat-web-update.sh" 755 || die "scripts/vnstat-web-update.sh 不存在或无法下载"
  # optional scripts
  download "$RAW_BASE/scripts/vnstat-quota-check.sh" "scripts/vnstat-quota-check.sh" 755 || true

  # lighttpd conf
  download "$RAW_BASE/lighttpd/vnstat-web.conf" "lighttpd/vnstat-web.conf" 644 || die "lighttpd/vnstat-web.conf 不存在或无法下载"
  download "$RAW_BASE/lighttpd/10-cgi-vnstat.conf" "lighttpd/10-cgi-vnstat.conf" 644 || true

  # config example (optional)
  download "$RAW_BASE/config/vnstat-web.conf.example" "config/vnstat-web.conf.example" 644 || true

  # systemd units (optional)
  download "$RAW_BASE/systemd/vnstat-web-update.service" "systemd/vnstat-web-update.service" 644 || true
  download "$RAW_BASE/systemd/vnstat-web-update.timer"   "systemd/vnstat-web-update.timer" 644 || true
  download "$RAW_BASE/systemd/vnstat-quota-check.service" "systemd/vnstat-quota-check.service" 644 || true
  download "$RAW_BASE/systemd/vnstat-quota-check.timer"   "systemd/vnstat-quota-check.timer" 644 || true

  # Install files into system
  install_web_files "web"
  install_cgi "cgi-bin/vnstat-web-config.cgi"
  install_scripts "scripts"
  install_systemd_units "systemd"
  install_lighttpd_vhost "$port" "lighttpd/vnstat-web.conf"

  # Validate lighttpd config before restart
  if ! lighttpd -tt -f /etc/lighttpd/lighttpd.conf; then
    err "lighttpd 配置检测失败。请查看：/var/log/lighttpd/error.log 或 journalctl -u lighttpd"
    exit 1
  fi

  restart_services

  ok "安装完成"
  echo
  echo "访问地址："
  echo "  http://<你的IP>:${port}/"
  echo
  echo "常用命令："
  echo "  手动更新：sudo /usr/local/bin/vnstat-web-update.sh"
  echo "  看 lighttpd：systemctl status lighttpd --no-pager"
  echo "  看日志：journalctl -u lighttpd -n 80 --no-pager"
}

main "$@"
