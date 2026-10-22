#!/bin/sh
# Rotates the well-known EMQX dashboard passwords. Nobody logs in to EMQX any more (the
# proxy uses the teamspace API key), so the new password is random and never stored.
# Idempotent: it does nothing once the known defaults are gone, and it logs no values.
U="${EMQX_DASHBOARD_UPSTREAM:?}"
USER_NAME="${EMQX_DASHBOARD_ADMIN:-teknoir}"
KNOWN="${EMQX_KNOWN_DEFAULT_PASSWORDS:-teknoir public}"
INTERVAL="${GUARD_INTERVAL_SECONDS:-600}"
W=/tmp/guard
mkdir -p "$W"

post() { # post <path> <bodyfile> [bearer]; prints the response body, exit 0 only on HTTP 2xx
  if [ -n "$3" ]; then
    wget -q -T 10 -O - --header 'Content-Type: application/json' --header "Authorization: Bearer $3" --post-file "$2" "$U$1"
  else
    wget -q -T 10 -O - --header 'Content-Type: application/json' --post-file "$2" "$U$1"
  fi
}

guard_once() { # returns 2 when EMQX is unreachable, else 0
  if ! wget -q -T 10 -O /dev/null "$U/status"; then return 2; fi
  for pw in $KNOWN; do
    printf '{"username":"%s","password":"%s"}' "$USER_NAME" "$pw" > "$W/login.json"
    resp=$(post /api/v5/login "$W/login.json") || continue
    token=$(printf '%s' "$resp" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || continue
    newpw="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)a1"
    printf '{"old_pwd":"%s","new_pwd":"%s"}' "$pw" "$newpw" > "$W/change.json"
    if post "/api/v5/users/$USER_NAME/change_pwd" "$W/change.json" "$token" >/dev/null; then
      echo "rotated a known default dashboard password for $USER_NAME"
    else
      echo "could not rotate a known default dashboard password for $USER_NAME"
    fi
    newpw=""; token=""; resp=""
    rm -f "$W/change.json"
  done
  rm -f "$W/login.json"
  return 0
}

while true; do
  guard_once
  if [ $? -eq 2 ]; then sleep 30; else sleep "$INTERVAL"; fi
done
