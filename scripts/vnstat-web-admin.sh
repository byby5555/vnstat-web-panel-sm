#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
[[ -f "$LIB" ]] || { echo "缺少 $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

ensure_auth_files

show_users(){
  echo "---- 用户列表 ----"
  jq -r '.users[] | "用户: \(.username)  创建: \(.created_at)  更新: \(.updated_at)"' "$USERS_FILE"
}

show_blocked(){
  echo "---- 已封锁 IP ----"
  jq -r 'to_entries[]? | "IP: \(.key)  时间: \(.value.blocked_at // "")  用户: \(.value.username // "")"' "$BLOCK_FILE" 2>/dev/null || true
}

reset_ip(){
  read -r -p "输入要解封的 IP: " ip
  [[ -n "$ip" ]] || return
  tmpf="$(mktemp)"
  jq --arg ip "$ip" 'del(.[$ip])' "$BLOCK_FILE" > "$tmpf" && mv "$tmpf" "$BLOCK_FILE"
  rm -f "${FAIL_DIR}/${ip}.count"
  echo "已解封 $ip"
}

reset_user_password(){
  read -r -p "输入用户名: " u
  read -r -s -p "输入新密码: " p; echo
  [[ -n "$u" && -n "$p" ]] || { echo "用户名或密码不能为空"; return; }
  salt="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  hash="$(printf '%s%s' "$salt" "$p" | sha256sum | awk '{print $1}')"
  now="$(date -Is)"
  tmpf="$(mktemp)"
  jq --arg u "$u" --arg s "$salt" --arg h "$hash" --arg n "$now" '(.users[]|select(.username==$u)|.salt)=$s | (.users[]|select(.username==$u)|.password_hash)=$h | (.users[]|select(.username==$u)|.updated_at)=$n' "$USERS_FILE" > "$tmpf" && mv "$tmpf" "$USERS_FILE"
  echo "已重置用户密码: $u"
}

while true; do
  echo
  echo "===== vnstat-web 安全管理 ====="
  echo "1) 显示用户"
  echo "2) 显示封锁 IP"
  echo "3) 解封 IP"
  echo "4) 重置用户密码"
  echo "0) 退出"
  read -r -p "请选择: " c
  case "$c" in
    1) show_users ;;
    2) show_blocked ;;
    3) reset_ip ;;
    4) reset_user_password ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
