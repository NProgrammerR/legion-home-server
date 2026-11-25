#!/bin/bash
# Power-cut watcher (user service power-watch.service). Every 30 s:
#  - mains lost     -> phone notification (with battery %)
#  - mains restored -> phone notification
#  - on battery and <= SHUTDOWN_AT % on two checks in a row -> notify, then clean poweroff
# Conservation mode keeps the battery near 60 %, so a full outage gives roughly 45 % of runtime.
# Testing: PS_DIR=<dir with ADP0/online and BAT0/capacity files> DRY_RUN=1 INTERVAL=1 power-watch.sh
PS_DIR=${PS_DIR:-/sys/class/power_supply}
SHUTDOWN_AT=${SHUTDOWN_AT:-15}
INTERVAL=${INTERVAL:-30}
DRY_RUN=${DRY_RUN:-0}
T=$(cat /home/legion/.ha_token)

notify() {
  echo "notify: $1 - $2"
  [ "$DRY_RUN" = 1 ] && return
  curl -sf -m 10 -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
    -d "{\"title\":\"$1\",\"message\":\"$2\"}" \
    http://localhost:8123/api/services/notify/mobile_app_phone >/dev/null || echo "notify failed (network down?)"
}

prev_ac=$(cat "$PS_DIR/ADP0/online")
low_count=0
echo "start: ac=$prev_ac battery=$(cat "$PS_DIR/BAT0/capacity")% shutdown_at=${SHUTDOWN_AT}%"
while true; do
  ac=$(cat "$PS_DIR/ADP0/online"); cap=$(cat "$PS_DIR/BAT0/capacity")
  if [ "$ac" != "$prev_ac" ]; then
    if [ "$ac" = 0 ]; then notify "legion: power cut" "Running on battery at ${cap}%. Clean shutdown at ${SHUTDOWN_AT}%."
    else notify "legion: power restored" "Mains back, battery at ${cap}%."; fi
    prev_ac=$ac
  fi
  if [ "$ac" = 0 ] && [ "$cap" -le "$SHUTDOWN_AT" ]; then
    low_count=$((low_count + 1))
    if [ $low_count -ge 2 ]; then
      notify "legion: shutting down" "Battery at ${cap}% on battery power. Powering off cleanly now. Press the power button when mains is back."
      echo "poweroff (battery ${cap}%)"
      [ "$DRY_RUN" = 1 ] && exit 0
      sleep 5
      sudo -n /usr/bin/systemctl start poweroff.target
      exit 0
    fi
  else
    low_count=0
  fi
  sleep "$INTERVAL"
done
