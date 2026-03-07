#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
[[ -f "$LIB" ]] || { echo "缺少 $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

ensure_auth_files

gen_strong_password(){
  local p
  p="$(tr -dc 'A-Za-z0-9@#%+=_' </dev/urandom | head -c 20 || true)"
  [[ -n "$p" ]] || p="$(rand_hex 12)"
  echo "$p"
}

show_users(){
  echo "---- 用户列表 ----"
  jq -r '.users[] | "用户: \(.username)  创建: \(.created_at)  更新: \(.updated_at)"' "$USERS_FILE"
}

show_blocked(){
  echo "---- 已封锁 IP ----"
  local out
  out="$(jq -r 'to_entries[]? | "IP: \(.key)  时间: \(.value.blocked_at // "")  用户: \(.value.username // "")"' "$BLOCK_FILE" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "暂无封锁 IP"
  else
    echo "$out"
  fi
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
    echo "用户不存在: $old_u"
    return
  fi
  if jq -e --arg u "$new_u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "新用户名已存在: $new_u"
    return
  fi
  rename_user "$old_u" "$new_u"
  echo "用户名已修改: $old_u -> $new_u"
}

change_password(){
  read -r -p "输入用户名: " u
  [[ -n "$u" ]] || { echo "用户名不能为空"; return; }
  if ! jq -e --arg u "$u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "用户不存在: $u"
    return
  fi
  read -r -s -p "输入新密码(留空自动生成强密码): " p; echo
  if [[ -z "$p" ]]; then
    p="$(gen_strong_password)"
    echo "自动生成密码: $p"
  fi
  set_user_password "$u" "$p"
  echo "密码已更新: $u"
}

reset_user_password(){
  read -r -p "输入用户名: " u
  [[ -n "$u" ]] || { echo "用户名不能为空"; return; }
  if ! jq -e --arg u "$u" '.users[]?|select(.username==$u)' "$USERS_FILE" >/dev/null; then
    echo "用户不存在: $u"
    return
  fi
  p="$(gen_strong_password)"
  set_user_password "$u" "$p"
  echo "已重置用户密码: $u"
  echo "新密码: $p"
}

show_login_hint(){
  echo "登录信息文件: /root/vnstat-web-login.txt"
  if [[ -f /root/vnstat-web-login.txt ]]; then
    cat /root/vnstat-web-login.txt
  fi
}

while true; do
  echo
  echo "===== vnstat-web 安全管理 ====="
  echo "1) 显示用户"
  echo "2) 显示封锁 IP"
  echo "3) 解封 IP"
  echo "4) 修改用户名"
  echo "5) 修改用户密码"
  echo "6) 重置用户密码(自动强密码)"
  echo "7) 查看登录信息"
  echo "0) 退出"
  read -r -p "请选择: " c
  case "$c" in
    1) show_users ;;
    2) show_blocked ;;
    3) unblock_ip ;;
    4) change_username ;;
    5) change_password ;;
    6) reset_user_password ;;
    7) show_login_hint ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
