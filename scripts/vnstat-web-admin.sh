#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
[[ -f "$LIB" ]] || { echo "缺少 $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

ensure_auth_files

LOGIN_INFO_FILE="/root/vnstat-web-login.txt"
LOGIN_INFO_BACKUP="/etc/vnstat-web/login.txt"

persist_login_file(){
  local u="$1" p="$2" now tmp
  now="$(date -Is)"
  tmp="$(mktemp)"
  printf 'username=%s\npassword=%s\ncreated_at=%s\n' "$u" "$p" "$now" > "$tmp"
  install -m 600 "$tmp" "$LOGIN_INFO_FILE"
  install -m 600 "$tmp" "$LOGIN_INFO_BACKUP"
  rm -f "$tmp"
}

show_login_file(){
  local f="$1"
  echo "登录信息文件: $f"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "文件不存在"
  fi
}

show_current_login_info(){
  local u
  u="$(jq -r '.users[0].username // empty' "$USERS_FILE" 2>/dev/null || true)"
  echo "当前登录用户名: ${u:-未知}"
  echo "当前密码只能在创建/修改/重置时保存，无法从哈希反推出。"
  echo
  show_login_file "$LOGIN_INFO_FILE"
  echo
  show_login_file "$LOGIN_INFO_BACKUP"
  echo
  echo "如果两个文件都没有密码，请在菜单选择 6 或 7 重置密码/账号。"
}

gen_strong_password(){
  local raw p
  raw="$(openssl rand -base64 64 2>/dev/null || head -c 64 /dev/urandom | base64)"
  p="$(printf "%s" "$raw" | tr -dc 'A-Za-z0-9@#%+=_' | cut -c1-20)"
  [[ ${#p} -ge 16 ]] || p="$(rand_hex 12)"
  echo "$p"
}

gen_username(){
  echo "vn$(rand_hex 3)"
}

show_users(){
  echo "---- 用户列表 ----"
  jq -r '.users[] | "用户: \(.username)  创建: \(.created_at)  更新: \(.updated_at)"' "$USERS_FILE"
}

show_blocked(){
  echo "---- 已封锁 IP ----"
  local out
  out="$(jq -r 'to_entries[]? | "IP: \(.key)  时间: \(.value.blocked_at // "")  用户: \(.value.username // "")"' "$BLOCK_FILE" 2>/dev/null || true)"
  [[ -n "$out" ]] && echo "$out" || echo "暂无封锁 IP"
}

unblock_ip(){
  read -r -p "输入要解封的 IP: " ip
  [[ -n "$ip" ]] || return
  tmpf="$(mktemp)"
  jq --arg ip "$ip" 'del(.[$ip])' "$BLOCK_FILE" > "$tmpf" && mv "$tmpf" "$BLOCK_FILE"
  rm -f "${FAIL_DIR}/${ip}.count"
  echo "已解封 $ip"
}

change_username(){
  read -r -p "输入当前用户名: " old_u
  read -r -p "输入新用户名: " new_u
  [[ -n "$old_u" && -n "$new_u" ]] || { echo "用户名不能为空"; return; }
  if ! jq -e --arg u "$old_u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "用户不存在: $old_u"; return
  fi
  if jq -e --arg u "$new_u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "新用户名已存在: $new_u"; return
  fi
  rename_user "$old_u" "$new_u"
  echo "用户名已修改: $old_u -> $new_u"
}

change_password(){
  read -r -p "输入用户名: " u
  [[ -n "$u" ]] || { echo "用户名不能为空"; return; }
  if ! jq -e --arg u "$u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "用户不存在: $u"; return
  fi
  read -r -s -p "输入新密码(留空自动生成强密码): " p; echo
  [[ -n "$p" ]] || p="$(gen_strong_password)"
  set_user_password "$u" "$p"
  persist_login_file "$u" "$p"
  echo "密码已更新: $u"
  echo "新密码: $p"
}

reset_user_password(){
  read -r -p "输入用户名: " u
  [[ -n "$u" ]] || { echo "用户名不能为空"; return; }
  if ! jq -e --arg u "$u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "用户不存在: $u"; return
  fi
  local p
  p="$(gen_strong_password)"
  set_user_password "$u" "$p"
  persist_login_file "$u" "$p"
  echo "已重置用户密码: $u"
  echo "新密码: $p"
}

reset_login_account(){
  local old_u new_u p now salt hash
  old_u="$(jq -r '.users[0].username // empty' "$USERS_FILE")"
  new_u="$(gen_username)"
  p="$(gen_strong_password)"
  salt="$(rand_hex 8)"
  hash="$(password_hash_from_salt "$salt" "$p")"
  now="$(date -Is)"
  jq -n --arg now "$now" --arg u "$new_u" --arg s "$salt" --arg h "$hash" '{users:[{username:$u,salt:$s,password_hash:$h,created_at:$now,updated_at:$now}]}' > "$USERS_FILE"
  persist_login_file "$new_u" "$p"
  echo "已重置默认登录账号"
  echo "旧账号: ${old_u:-N/A}"
  echo "新账号: $new_u"
  echo "新密码: $p"
}

show_login_hint(){
  show_current_login_info
}

restart_services(){
  echo "重启 lighttpd..."
  systemctl restart lighttpd
  echo "重启 vnstat-web-update.timer..."
  systemctl restart vnstat-web-update.timer 2>/dev/null || true
  echo "服务重启完成"
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
    echo "检测到 lighttpd 主配置损坏，已备份到 $backup 并重建最小配置"
  else
    echo "未找到 lighttpd 主配置，正在创建最小配置"
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

run_update_installation(){
  local repo_owner="byby5555" repo_name="vnstat-web-panel-sm" repo_branch="main"
  local tmp repo_dir conf="/etc/vnstat-web.conf" port="8888" web_root="/var/www/vnstat-web"
  local auth_code home_code

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 运行更新。"; return 1; }

  echo "将从 GitHub main 更新 vnstat-web 已安装文件。"
  echo "不会重置登录账号、密码、/etc/vnstat-web.conf 或 vnStat 历史数据库。"
  read -r -p "确认更新? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; return 0 ;;
  esac

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "下载最新版本..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar jq >/dev/null 2>&1 || true
  curl -fsSL "https://codeload.github.com/${repo_owner}/${repo_name}/tar.gz/refs/heads/${repo_branch}" -o "$tmp/repo.tgz" || { echo "下载失败"; return 1; }
  tar -xzf "$tmp/repo.tgz" -C "$tmp" || { echo "解压失败"; return 1; }
  repo_dir="$(find "$tmp" -maxdepth 1 -type d -name "${repo_name}-*" | head -n 1)"
  [[ -n "${repo_dir:-}" ]] || { echo "未找到解压后的仓库目录"; return 1; }

  echo "验证脚本语法..."
  bash -n "$repo_dir/install.sh" || return 1
  bash -n "$repo_dir/uninstall.sh" || return 1
  bash -n "$repo_dir/scripts/vnstat-web-update.sh" || return 1
  bash -n "$repo_dir/scripts/vnstat-quota-check.sh" || return 1
  bash -n "$repo_dir/scripts/vnstat-web-auth-lib.sh" || return 1
  bash -n "$repo_dir/scripts/vnstat-web-admin.sh" || return 1
  bash -n "$repo_dir/cgi-bin/vnstat-web-auth.cgi" || return 1
  bash -n "$repo_dir/cgi-bin/vnstat-web-admin.cgi" || return 1
  bash -n "$repo_dir/cgi-bin/vnstat-web-config.cgi" || return 1
  bash -n "$repo_dir/cgi-bin/vnstat-web-data.cgi" || return 1

  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    . "$conf"
    port="${PORT:-$port}"
    web_root="${WEB_ROOT:-${WEB_PATH:-$web_root}}"
  fi

  echo "更新 Web 文件..."
  install -d -m 755 "$web_root"
  cp -a "$repo_dir/web/." "$web_root/"

  echo "更新脚本、CGI 与管理组件..."
  install -d -m 755 /usr/local/lib /usr/local/bin /usr/lib/cgi-bin
  install -m 755 "$repo_dir/scripts/vnstat-web-update.sh" /usr/local/bin/vnstat-web-update.sh
  install -m 755 "$repo_dir/scripts/vnstat-quota-check.sh" /usr/local/bin/vnstat-quota-check.sh
  install -m 755 "$repo_dir/scripts/vnstat-web-auth-lib.sh" /usr/local/lib/vnstat-web-auth-lib.sh
  install -m 755 "$repo_dir/scripts/vnstat-web-admin.sh" /usr/local/bin/vnstat-web-admin.sh
  install -m 755 "$repo_dir/uninstall.sh" /usr/local/bin/vnstat-web-uninstall.sh
  install -m 755 "$repo_dir/cgi-bin/vnstat-web-config.cgi" /usr/lib/cgi-bin/vnstat-web-config.cgi
  install -m 755 "$repo_dir/cgi-bin/vnstat-web-auth.cgi" /usr/lib/cgi-bin/vnstat-web-auth.cgi
  install -m 755 "$repo_dir/cgi-bin/vnstat-web-admin.cgi" /usr/lib/cgi-bin/vnstat-web-admin.cgi
  install -m 755 "$repo_dir/cgi-bin/vnstat-web-data.cgi" /usr/lib/cgi-bin/vnstat-web-data.cgi

  cat > /usr/local/bin/vn <<'EOS'
#!/usr/bin/env bash
exec /usr/local/bin/vnstat-web-admin.sh "$@"
EOS
  chmod 755 /usr/local/bin/vn

  echo "更新 lighttpd 配置..."
  repair_lighttpd_main_conf
  if command -v lighty-enable-mod >/dev/null 2>&1; then
    lighty-enable-mod alias redirect cgi >/dev/null 2>&1 || true
  fi
  install -m 644 "$repo_dir/lighttpd/50-vnstat-alias.conf" /etc/lighttpd/conf-available/50-vnstat-alias.conf
  ln -sf /etc/lighttpd/conf-available/50-vnstat-alias.conf /etc/lighttpd/conf-enabled/50-vnstat-alias.conf
  if [[ -f "$repo_dir/lighttpd/51-vnstat-root-redirect.conf" ]]; then
    install -m 644 "$repo_dir/lighttpd/51-vnstat-root-redirect.conf" /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf
    ln -sf /etc/lighttpd/conf-available/51-vnstat-root-redirect.conf /etc/lighttpd/conf-enabled/51-vnstat-root-redirect.conf
  fi
  if [[ -f "$repo_dir/lighttpd/98-vnstat-web-nocache.conf" ]]; then
    install -m 644 "$repo_dir/lighttpd/98-vnstat-web-nocache.conf" /etc/lighttpd/conf-available/98-vnstat-web-nocache.conf
    ln -sf /etc/lighttpd/conf-available/98-vnstat-web-nocache.conf /etc/lighttpd/conf-enabled/98-vnstat-web-nocache.conf
  fi
  lighttpd -tt -f /etc/lighttpd/lighttpd.conf || return 1

  if [[ -d "$repo_dir/systemd" ]]; then
    cp -a "$repo_dir/systemd/"* /etc/systemd/system/ || true
    systemctl daemon-reload
    systemctl enable --now vnstat-web-update.timer >/dev/null 2>&1 || true
  fi

  echo "生成最新数据..."
  /usr/local/bin/vnstat-web-update.sh || return 1

  echo "重启程序和服务..."
  restart_services

  echo "验证 HTTP 与认证接口..."
  home_code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" || true)"
  auth_code="$(curl -s -o /tmp/vnstat-web-auth-check.json -w "%{http_code}" -X POST "http://127.0.0.1:${port}/cgi-bin/vnstat-web-auth.cgi" -H 'Content-Type: application/json' --data '{"action":"status"}' || true)"
  echo "首页 HTTP: $home_code"
  echo "认证接口 HTTP: $auth_code"
  if [[ "$auth_code" != "200" ]] || ! jq -e '.ok == true' /tmp/vnstat-web-auth-check.json >/dev/null 2>&1; then
    echo "认证接口验证失败："
    cat /tmp/vnstat-web-auth-check.json 2>/dev/null || true
    return 1
  fi

  echo "更新完成并验证通过"
}

clean_generated_files(){
  local conf="/etc/vnstat-web.conf" web_root="/var/www/vnstat-web" size_before size_after
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    . "$conf"
    web_root="${WEB_ROOT:-${WEB_PATH:-$web_root}}"
  fi

  echo "将清理网页生成文件，不会删除 vnStat 原始历史数据库。"
  echo "网页目录: $web_root"
  if [[ ! -d "$web_root" ]]; then
    echo "网页目录不存在，跳过。"
    return
  fi

  size_before="$(du -sh "$web_root" 2>/dev/null | awk '{print $1}')"
  echo "当前大小: ${size_before:-未知}"
  read -r -p "确认清理网页生成文件? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES)
      find "$web_root" -maxdepth 1 -type f \( \
        -name '*.json' -o -name '*.txt' -o -name '*.png' -o -name '*.tmp' \
      \) -delete
      if [[ -x /usr/local/bin/vnstat-web-update.sh ]]; then
        /usr/local/bin/vnstat-web-update.sh || true
      fi
      size_after="$(du -sh "$web_root" 2>/dev/null | awk '{print $1}')"
      echo "清理完成，当前大小: ${size_after:-未知}"
      ;;
    *) echo "已取消" ;;
  esac
}

clean_auth_runtime(){
  echo "将清理登录会话、失败计数和封锁记录，不会修改用户名/密码。"
  read -r -p "确认清理认证运行状态? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES)
      rm -rf /var/lib/vnstat-web/auth/sessions/* /var/lib/vnstat-web/auth/fails/* 2>/dev/null || true
      printf '{}\n' > /var/lib/vnstat-web/auth/blocked.json
      echo "认证运行状态已清理"
      ;;
    *) echo "已取消" ;;
  esac
}

reset_vnstat_database(){
  echo "危险操作：这会删除 /var/lib/vnstat 下的 vnStat 原始历史数据库。"
  echo "删除后流量统计会重新开始，历史数据不可恢复。"
  read -r -p "如确认重置，请输入 DELETE: " ans
  [[ "$ans" == "DELETE" ]] || { echo "已取消"; return; }
  systemctl stop vnstat 2>/dev/null || true
  rm -rf /var/lib/vnstat/*
  systemctl start vnstat 2>/dev/null || true
  if [[ -x /usr/local/bin/vnstat-web-update.sh ]]; then
    /usr/local/bin/vnstat-web-update.sh || true
  fi
  echo "vnStat 数据库已重置"
}

run_clean_menu(){
  while true; do
    echo
    echo "===== vnstat-web 清理菜单 ====="
    echo "1) 清理网页生成文件(json/txt/png)"
    echo "2) 清理登录会话/封锁记录"
    echo "3) 重置 vnStat 原始历史数据库(危险)"
    echo "0) 返回"
    read -r -p "请选择: " c
    case "$c" in
      1) clean_generated_files ;;
      2) clean_auth_runtime ;;
      3) reset_vnstat_database ;;
      0) return ;;
      *) echo "无效选项" ;;
    esac
  done
}

run_uninstall(){
  read -r -p "确认卸载 vnstat-web? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES)
      if [[ -x /usr/local/bin/vnstat-web-uninstall.sh ]]; then
        /usr/local/bin/vnstat-web-uninstall.sh
      elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/uninstall.sh" ]]; then
        bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/uninstall.sh"
      else
        echo "未找到卸载脚本，请重新下载安装或手动执行仓库中的 uninstall.sh。"
      fi
      ;;
    *) echo "已取消" ;;
  esac
}

if [[ "${1:-}" == "clean" ]]; then
  run_clean_menu
  exit 0
fi

if [[ "${1:-}" == "update" ]]; then
  run_update_installation
  exit $?
fi

while true; do
  echo
  echo "===== vnstat-web 安全管理 ====="
  echo "1) 显示用户"
  echo "2) 显示封锁 IP"
  echo "3) 解封 IP"
  echo "4) 修改用户名"
  echo "5) 修改用户密码"
  echo "6) 重置用户密码(自动强密码)"
  echo "7) 重置登录账号(自动新用户名+强密码)"
  echo "8) 查看登录信息"
  echo "9) 重启服务"
  echo "10) 更新程序并验证"
  echo "11) 清理数据/缓存"
  echo "12) 卸载 vnstat-web"
  echo "0) 退出"
  read -r -p "请选择: " c
  case "$c" in
    1) show_users ;;
    2) show_blocked ;;
    3) unblock_ip ;;
    4) change_username ;;
    5) change_password ;;
    6) reset_user_password ;;
    7) reset_login_account ;;
    8) show_login_hint ;;
    9) restart_services ;;
    10) run_update_installation ;;
    11) run_clean_menu ;;
    12) run_uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
