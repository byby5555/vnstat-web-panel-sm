#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
WEB_ROOT="/var/www/vnstat-web"

reply_json(){ printf "Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s" "$1"; }
reply_text(){ printf "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n"; cat "$1"; }
reply_file(){
  local f="$1" ctype="$2"
  printf "Content-Type: %s\r\nCache-Control: no-store\r\n\r\n" "$ctype"
  cat "$f"
}

query_get(){
  local k="$1"
  echo "${QUERY_STRING:-}" | awk -v k="$k" -F'&' '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]==k){print a[2]; exit}}}'
}
urldecode(){ local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

[[ -f "$LIB" ]] || { reply_json '{"ok":false,"err":"auth_lib_missing"}'; exit 0; }
# shellcheck disable=SC1090
. "$LIB"

ensure_auth_files
cleanup_auth_runtime

TOKEN="${HTTP_X_SESSION_TOKEN:-}"
[[ -n "$TOKEN" ]] || TOKEN="$(urldecode "$(query_get session_token || true)")"
SESSION_USER="$(get_session_user "$TOKEN" 2>/dev/null || true)"
[[ -n "$SESSION_USER" ]] || { reply_json '{"ok":false,"err":"unauthorized"}'; exit 0; }

NAME="$(urldecode "$(query_get name || true)")"
case "$NAME" in
  vnstat.json)
    reply_file "$WEB_ROOT/vnstat.json" "application/json"
    ;;
  vnstat_5min.json)
    reply_file "$WEB_ROOT/vnstat_5min.json" "application/json"
    ;;
  summary.txt)
    reply_text "$WEB_ROOT/summary.txt"
    ;;
  server_time.json)
    reply_file "$WEB_ROOT/server_time.json" "application/json"
    ;;
  quota.json)
    reply_file "$WEB_ROOT/quota.json" "application/json"
    ;;
  hourly.png)
    reply_file "$WEB_ROOT/hourly.png" "image/png"
    ;;
  daily.png)
    reply_file "$WEB_ROOT/daily.png" "image/png"
    ;;
  monthly.png)
    reply_file "$WEB_ROOT/monthly.png" "image/png"
    ;;
  *)
    reply_json '{"ok":false,"err":"bad_name"}'
    ;;
esac
