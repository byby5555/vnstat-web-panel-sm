#!/usr/bin/env bash
set -euo pipefail

# 轻量 CGI：读/写 /etc/vnstat-web/quota.json
# - GET:  返回 JSON
# - POST: 支持 application/x-www-form-urlencoded 或 JSON

CONF="/etc/vnstat-web/quota.json"
CFG="/etc/vnstat-web.conf"
DEFAULT_JSON='{"quota_gb":1024,"alert_pct":90,"danger_pct":100,"auto_shutdown":0,"shutdown_pct":100,"month_start_day":1,"tg_enabled":0,"tg_bot_token":"","tg_chat_id":""}'

reply(){
  # lighttpd/CGI 要求 \r\n
  printf "Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s" "$1"
}

http_400(){ reply '{"ok":false,"err":"bad_request"}'; exit 0; }

ensure_conf(){
  mkdir -p "$(dirname "$CONF")" 2>/dev/null || true
  if [ ! -f "$CONF" ]; then
    umask 027
    printf "%s" "$DEFAULT_JSON" >"$CONF" || true
  fi
}

urldecode(){
  # 仅用于数字参数，这里实现一个通用解码，避免用户自定义时踩坑
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

read_body(){
  local len="${CONTENT_LENGTH:-0}"
  if [ -n "$len" ] && [[ "$len" =~ ^[0-9]+$ ]] && [ "$len" -gt 0 ]; then
    head -c "$len" || true
  else
    cat || true
  fi
}

parse_form(){
  # $1=body, $2=key ; return first match
  # shellcheck disable=SC2016
  echo "$1" | awk -v k="$2" -F'&' '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]==k){print a[2]; exit}}}'
}

json_get(){
  # 极简 JSON 取值（只取数字字段）；避免依赖 jq
  # $1=body, $2=key
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p" | head -n1
}

json_get_str(){
  # 极简 JSON 字符串取值
  # $1=body, $2=key
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

ensure_conf

API_TOKEN=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG" || true
  API_TOKEN="${QUOTA_TOKEN:-${API_TOKEN:-}}"
fi
if [ -z "$API_TOKEN" ]; then
  reply '{"ok":false,"err":"unauthorized"}'
  exit 0
fi

if [ "${REQUEST_METHOD:-GET}" = "GET" ]; then
  reply "$(cat "$CONF" 2>/dev/null || echo "$DEFAULT_JSON")"
  exit 0
fi

BODY="$(read_body)"
CTYPE="${CONTENT_TYPE:-}"

REQ_TOKEN="${HTTP_X_AUTH_TOKEN:-}"
if [ -z "$REQ_TOKEN" ]; then
  if echo "$CTYPE" | grep -qi 'application/json'; then
    REQ_TOKEN="$(json_get_str "$BODY" token)"
  else
    REQ_TOKEN="$(parse_form "$BODY" token || true)"
    REQ_TOKEN="$(urldecode "${REQ_TOKEN:-}")"
  fi
fi
if [ -z "$REQ_TOKEN" ] || [ "$REQ_TOKEN" != "$API_TOKEN" ]; then
  reply '{"ok":false,"err":"unauthorized"}'
  exit 0
fi

Q=""; A=""; D=""; AS=""; SP=""; MSD=""; TG_ON=""; TG_TOKEN=""; TG_CHAT=""
if echo "$CTYPE" | grep -qi 'application/json'; then
  Q="$(json_get "$BODY" quota_gb)"
  A="$(json_get "$BODY" alert_pct)"
  D="$(json_get "$BODY" danger_pct)"
  AS="$(json_get "$BODY" auto_shutdown)"
  SP="$(json_get "$BODY" shutdown_pct)"
  MSD="$(json_get "$BODY" month_start_day)"
  TG_ON="$(json_get "$BODY" tg_enabled)"
  TG_TOKEN="$(json_get_str "$BODY" tg_bot_token)"
  TG_CHAT="$(json_get_str "$BODY" tg_chat_id)"
else
  Q="$(parse_form "$BODY" quota_gb)"
  A="$(parse_form "$BODY" alert_pct)"
  D="$(parse_form "$BODY" danger_pct)"
  AS="$(parse_form "$BODY" auto_shutdown)"
  SP="$(parse_form "$BODY" shutdown_pct)"
  MSD="$(parse_form "$BODY" month_start_day)"
  TG_ON="$(parse_form "$BODY" tg_enabled)"
  TG_TOKEN="$(parse_form "$BODY" tg_bot_token)"
  TG_CHAT="$(parse_form "$BODY" tg_chat_id)"
  Q="$(urldecode "${Q:-}")"; A="$(urldecode "${A:-}")"; D="$(urldecode "${D:-}")"
  AS="$(urldecode "${AS:-}")"; SP="$(urldecode "${SP:-}")"; MSD="$(urldecode "${MSD:-}")"
  TG_ON="$(urldecode "${TG_ON:-}")"
  TG_TOKEN="$(urldecode "${TG_TOKEN:-}")"; TG_CHAT="$(urldecode "${TG_CHAT:-}")"
fi

[[ "$Q" =~ ^[0-9]+$ ]] && [[ "$A" =~ ^[0-9]+$ ]] && [[ "$D" =~ ^[0-9]+$ ]] || http_400
[[ "$AS" =~ ^[0-9]+$ ]] || AS="0"
[[ "$SP" =~ ^[0-9]+$ ]] || SP="100"
[[ "$MSD" =~ ^[0-9]+$ ]] || MSD="1"
[[ "$TG_ON" =~ ^[0-9]+$ ]] || TG_ON="0"

(( Q >= 1 )) || http_400
(( A >= 1 && A <= 100 )) || http_400
(( D >= 1 && D <= 100 )) || http_400
(( D >= A )) || D="$A"
(( SP >= 1 && SP <= 100 )) || SP="100"
(( MSD >= 1 && MSD <= 31 )) || MSD="1"
[[ "$AS" == "0" || "$AS" == "1" ]] || AS="0"
[[ "$TG_ON" == "0" || "$TG_ON" == "1" ]] || TG_ON="0"

umask 027
printf '{"quota_gb":%s,"alert_pct":%s,"danger_pct":%s,"auto_shutdown":%s,"shutdown_pct":%s,"month_start_day":%s,"tg_enabled":%s,"tg_bot_token":"%s","tg_chat_id":"%s"}' \
  "$Q" "$A" "$D" "$AS" "$SP" "$MSD" "$TG_ON" "$TG_TOKEN" "$TG_CHAT" >"$CONF" || http_400
reply '{"ok":true}'
