#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
[[ -f "$LIB" ]] || { echo "缺少 $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

ensure_auth_files

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

persist_login_file(){
  local u="$1" p="$2" now
  now="$(date -Is)"
  printf 'username=%s\npassword=%s\ncreated_at=%s\n' "$u" "$p" "$now" > /root/vnstat-web-login.txt
  chmod 600 /root/vnstat-web-login.txt
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
  echo "登录信息文件: /root/vnstat-web-login.txt"
  [[ -f /root/vnstat-web-login.txt ]] && cat /root/vnstat-web-login.txt || echo "文件不存在"
}

restart_services(){
  echo "重启 lighttpd..."
  systemctl restart lighttpd
  echo "重启 vnstat-web-update.timer..."
  systemctl restart vnstat-web-update.timer 2>/dev/null || true
  echo "服务重启完成"
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
  echo "10) 清理数据/缓存"
  echo "11) 卸载 vnstat-web"
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
    10) run_clean_menu ;;
    11) run_uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
