#!/usr/bin/env bash
set -Eeuo pipefail

AUTH_DIR="/etc/vnstat-web"
USERS_FILE="${AUTH_DIR}/users.json"
AUTH_CFG_FILE="${AUTH_DIR}/auth.json"
STATE_DIR="/var/lib/vnstat-web/auth"
SESS_DIR="${STATE_DIR}/sessions"
FAIL_DIR="${STATE_DIR}/fails"
BLOCK_FILE="${STATE_DIR}/blocked_ips.json"
AUTH_LOG="/var/log/vnstat-web-auth.log"

mkdir -p "$AUTH_DIR" "$SESS_DIR" "$FAIL_DIR" "$STATE_DIR"

get_auth_cfg(){
  local k="$1" def="$2"
  if [[ -f "$AUTH_CFG_FILE" ]]; then
    jq -r --arg k "$k" --arg d "$def" '.[$k] // $d' "$AUTH_CFG_FILE" 2>/dev/null || echo "$def"
  else
    echo "$def"
  fi
}

ensure_auth_files(){
  local ttl maxf
  ttl="$(get_auth_cfg session_ttl_seconds 43200)"
  maxf="$(get_auth_cfg max_login_failures 5)"
  if [[ ! -f "$AUTH_CFG_FILE" ]]; then
    umask 027
    printf '{"session_ttl_seconds":%s,"max_login_failures":%s}\n' "$ttl" "$maxf" > "$AUTH_CFG_FILE"
  fi
  if [[ ! -f "$USERS_FILE" ]]; then
    local salt hash now
    now="$(date -Is)"
    salt="$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    hash="$(printf '%s%s' "$salt" 'admin123456' | sha256sum | awk '{print $1}')"
    umask 027
    jq -n --arg now "$now" --arg salt "$salt" --arg hash "$hash" '{users:[{username:"admin",salt:$salt,password_hash:$hash,created_at:$now,updated_at:$now}]}' > "$USERS_FILE"
  fi
  if [[ ! -f "$BLOCK_FILE" ]]; then
    echo '{}' > "$BLOCK_FILE"
    chmod 640 "$BLOCK_FILE" || true
  fi
}

mask_ip(){
  local ip="$1"
  [[ -z "$ip" ]] && { echo "unknown"; return; }
  echo "$ip" | sed 's/\.[0-9]\+$/.*./; s/:.*$/::/'
}

client_ip(){
  echo "${HTTP_X_FORWARDED_FOR:-${REMOTE_ADDR:-unknown}}" | awk -F',' '{gsub(/^ +| +$/,"",$1); print $1}'
}

is_ip_blocked(){
  local ip="$1"
  jq -e --arg ip "$ip" 'has($ip)' "$BLOCK_FILE" >/dev/null 2>&1
}

record_failed_login(){
  local ip="$1" username="$2"
  local maxf failfile count now
  maxf="$(get_auth_cfg max_login_failures 5)"
  failfile="${FAIL_DIR}/${ip}.count"
  count=0
  [[ -f "$failfile" ]] && count="$(cat "$failfile" 2>/dev/null || echo 0)"
  count=$((count + 1))
  echo "$count" > "$failfile"
  now="$(date -Is)"
  if (( count >= maxf )); then
    tmpf="$(mktemp)"
    jq --arg ip "$ip" --arg now "$now" --arg user "$username" '.[$ip]={blocked_at:$now,reason:"too_many_failures",username:$user}' "$BLOCK_FILE" > "$tmpf" && mv "$tmpf" "$BLOCK_FILE"
    echo "$now block ip=$ip user=$username reason=too_many_failures" >> "$AUTH_LOG"
  else
    echo "$now failed ip=$ip user=$username count=$count" >> "$AUTH_LOG"
  fi
}

clear_failed_login(){
  local ip="$1"
  rm -f "${FAIL_DIR}/${ip}.count"
}

verify_user(){
  local username="$1" password="$2"
  local salt hash
  salt="$(jq -r --arg u "$username" '.users[]?|select(.username==$u)|.salt // empty' "$USERS_FILE")"
  [[ -n "$salt" ]] || return 1
  hash="$(printf '%s%s' "$salt" "$password" | sha256sum | awk '{print $1}')"
  jq -e --arg u "$username" --arg h "$hash" '.users[]?|select(.username==$u and .password_hash==$h)' "$USERS_FILE" >/dev/null
}

create_session(){
  local username="$1" token now ttl expire
  now="$(date +%s)"
  ttl="$(get_auth_cfg session_ttl_seconds 43200)"
  expire=$((now + ttl))
  token="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  jq -n --arg u "$username" --argjson e "$expire" --arg c "$(date -Is)" '{username:$u,expire_at:$e,created_at:$c}' > "${SESS_DIR}/${token}.json"
  chmod 640 "${SESS_DIR}/${token}.json" || true
  echo "$token"
}

get_session_user(){
  local token="$1"
  local f now exp user
  [[ -n "$token" ]] || return 1
  f="${SESS_DIR}/${token}.json"
  [[ -f "$f" ]] || return 1
  now="$(date +%s)"
  exp="$(jq -r '.expire_at // 0' "$f" 2>/dev/null || echo 0)"
  if (( now > exp )); then
    rm -f "$f"
    return 1
  fi
  user="$(jq -r '.username // empty' "$f")"
  [[ -n "$user" ]] || return 1
  echo "$user"
}

destroy_session(){
  local token="$1"
  [[ -n "$token" ]] && rm -f "${SESS_DIR}/${token}.json"
}

session_token_from_env(){
  local body="${1:-}"
  local token="${HTTP_X_SESSION_TOKEN:-}"
  if [[ -z "$token" && -n "$body" ]]; then
    token="$(echo "$body" | sed -n 's/.*"session_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  echo "$token"
}

cleanup_auth_runtime(){
  local now old
  now="$(date +%s)"
  find "$SESS_DIR" -type f -name '*.json' | while read -r f; do
    old="$(jq -r '.expire_at // 0' "$f" 2>/dev/null || echo 0)"
    (( old > 0 && now > old )) && rm -f "$f"
  done
}
