#!/bin/sh
# Push a phone notification through Home Assistant when a user unit fails.
# Called by backup-failure-notify@.service (OnFailure= of backup.service). Arg: failed unit name.
UNIT="${1:-unknown}"
T=$(cat /home/legion/.ha_token)
LAST=$(journalctl --user -u "$UNIT" -n 3 --no-pager -o cat 2>/dev/null | tail -c 300 | tr '"\\\n' "'/ ")
curl -sf -m 20 -X POST \
  -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d "{\"title\":\"legion: $UNIT failed\",\"message\":\"$LAST\"}" \
  http://localhost:8123/api/services/notify/mobile_app_phone >/dev/null
