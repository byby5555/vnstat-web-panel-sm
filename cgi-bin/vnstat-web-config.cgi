#!/usr/bin/env bash
set -euo pipefail

# 轻量 CGI：读/写 /etc/vnstat-web/quota.json
# - GET:  返回 JSON
# - POST: 支持 application/x-www-form-urlencoded 或 JSON

CONF="/etc/vnstat-web/quota.json"
DEFAULT_JSON='{"quota_gb":1024,"alert_pct":90,"danger_pct":100}'

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

ensure_conf

if [ "${REQUEST_METHOD:-GET}" = "GET" ]; then
  reply "$(cat "$CONF" 2>/dev/null || echo "$DEFAULT_JSON")"
  exit 0
fi

BODY="$(read_body)"
CTYPE="${CONTENT_TYPE:-}"

Q=""; A=""; D=""
if echo "$CTYPE" | grep -qi 'application/json'; then
  Q="$(json_get "$BODY" quota_gb)"
  A="$(json_get "$BODY" alert_pct)"
  D="$(json_get "$BODY" danger_pct)"
else
  Q="$(parse_form "$BODY" quota_gb)"
  A="$(parse_form "$BODY" alert_pct)"
  D="$(parse_form "$BODY" danger_pct)"
  Q="$(urldecode "${Q:-}")"; A="$(urldecode "${A:-}")"; D="$(urldecode "${D:-}")"
fi

[[ "$Q" =~ ^[0-9]+$ ]] && [[ "$A" =~ ^[0-9]+$ ]] && [[ "$D" =~ ^[0-9]+$ ]] || http_400

(( Q >= 1 )) || http_400
(( A >= 1 && A <= 100 )) || http_400
(( D >= 1 && D <= 100 )) || http_400
(( D >= A )) || D="$A"

umask 027
printf '{"quota_gb":%s,"alert_pct":%s,"danger_pct":%s}' "$Q" "$A" "$D" >"$CONF" || http_400
reply '{"ok":true}'
