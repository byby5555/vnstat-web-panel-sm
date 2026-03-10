#!/usr/bin/env bash
set -Eeuo pipefail

LIB="/usr/local/lib/vnstat-web-auth-lib.sh"
if [[ ! -f "$LIB" ]]; then
  printf "Content-Type: application/json\r\n\r\n{\"ok\":false,\"err\":\"auth_lib_missing\"}"
  exit 0
fi
# shellcheck disable=SC1090
. "$LIB"

reply(){ printf "Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s" "$1"; }
read_body(){ local len="${CONTENT_LENGTH:-0}"; [[ "$len" =~ ^[0-9]+$ ]] && head -c "$len" || cat; }
json_get_str(){
  local body="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty | if type=="string" then . else "" end' <<<"$body" 2>/dev/null || true
  else
    echo "$body" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

ensure_auth_files
cleanup_auth_runtime

BODY="$(read_body)"
ACTION="$(json_get_str "$BODY" action)"
TOKEN="$(session_token_from_env "$BODY")"
IP="$(client_ip)"

case "$ACTION" in
  login)
    if is_ip_blocked "$IP"; then
      echo "$(date -Is) blocked-login ip=$IP" >> "$AUTH_LOG"
      reply '{"ok":false,"err":"ip_blocked"}'
      exit 0
    fi
    USERNAME="$(json_get_str "$BODY" username)"
    PASSWORD="$(json_get_str "$BODY" password)"
    if verify_user "$USERNAME" "$PASSWORD"; then
      clear_failed_login "$IP"
      TOKEN_NEW="$(create_session "$USERNAME")"
      echo "$(date -Is) login ok ip=$IP user=$USERNAME" >> "$AUTH_LOG"
      reply "{\"ok\":true,\"session_token\":\"$TOKEN_NEW\",\"username\":\"$USERNAME\"}"
    else
      record_failed_login "$IP" "$USERNAME"
      reply '{"ok":false,"err":"invalid_credentials"}'
    fi
    ;;
  status)
    if USER="$(get_session_user "$TOKEN" 2>/dev/null)"; then
      reply "{\"ok\":true,\"authenticated\":true,\"username\":\"$USER\"}"
    else
      reply '{"ok":true,"authenticated":false}'
    fi
    ;;
  logout)
    destroy_session "$TOKEN"
    reply '{"ok":true}'
    ;;
  *)
    reply '{"ok":false,"err":"bad_action"}'
    ;;
esac
