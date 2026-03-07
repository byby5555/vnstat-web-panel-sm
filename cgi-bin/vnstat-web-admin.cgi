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
json_get_str(){ echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1; }

ensure_auth_files
cleanup_auth_runtime

BODY="$(read_body)"
ACTION="$(json_get_str "$BODY" action)"
TOKEN="$(session_token_from_env "$BODY")"
SESSION_USER="$(get_session_user "$TOKEN" 2>/dev/null || true)"

if [[ -z "$SESSION_USER" ]]; then
  reply '{"ok":false,"err":"unauthorized"}'
  exit 0
fi

case "$ACTION" in
  list)
    USERS_JSON="$(jq -c '[.users[] | {username,created_at,updated_at}]' "$USERS_FILE" 2>/dev/null || echo '[]')"
    BLOCK_JSON="$(jq -c 'to_entries|map({ip:.key,blocked_at:(.value.blocked_at // ""),username:(.value.username // "")})' "$BLOCK_FILE" 2>/dev/null || echo '[]')"
    reply "{\"ok\":true,\"current_user\":\"$SESSION_USER\",\"users\":$USERS_JSON,\"blocked_ips\":$BLOCK_JSON}"
    ;;
  unblock_ip)
    IP="$(json_get_str "$BODY" ip)"
    if [[ -z "$IP" ]]; then
      reply '{"ok":false,"err":"bad_ip"}'
      exit 0
    fi
    tmpf="$(mktemp)"
    jq --arg ip "$IP" 'del(.[$ip])' "$BLOCK_FILE" > "$tmpf" && mv "$tmpf" "$BLOCK_FILE"
    rm -f "${FAIL_DIR}/${IP}.count"
    echo "$(date -Is) unblock ip=$IP by=$SESSION_USER" >> "$AUTH_LOG"
    reply '{"ok":true}'
    ;;
  reset_password)
    TARGET="$(json_get_str "$BODY" username)"
    NEWPASS="$(json_get_str "$BODY" new_password)"
    [[ -n "$TARGET" && -n "$NEWPASS" ]] || { reply '{"ok":false,"err":"bad_request"}'; exit 0; }
    SALT="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    HASH="$(printf '%s%s' "$SALT" "$NEWPASS" | sha256sum | awk '{print $1}')"
    NOW="$(date -Is)"
    tmpf="$(mktemp)"
    jq --arg u "$TARGET" --arg s "$SALT" --arg h "$HASH" --arg n "$NOW" '(.users[]|select(.username==$u)|.salt)=$s | (.users[]|select(.username==$u)|.password_hash)=$h | (.users[]|select(.username==$u)|.updated_at)=$n' "$USERS_FILE" > "$tmpf" && mv "$tmpf" "$USERS_FILE"
    echo "$(date -Is) reset_password user=$TARGET by=$SESSION_USER" >> "$AUTH_LOG"
    reply '{"ok":true}'
    ;;
  *)
    reply '{"ok":false,"err":"bad_action"}'
    ;;
esac
