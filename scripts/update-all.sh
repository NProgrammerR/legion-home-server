#!/bin/bash
# Monthly update of the legion server. Run by hand (with Claude), not on a timer.
#
#   update-all.sh            = --check: report what is out of date, change nothing
#   update-all.sh --apply    = back up, apt full-upgrade (incl. Docker), pull + recreate
#                              every compose stack, health-check, notify the phone
#
# Before --apply: read the release notes of Home Assistant and Immich for breaking changes.
# Images that are pinned to a version (matterjs-server) are only reported, never bumped:
# change the tag in the compose file by hand.
# Log: ~/update-logs/update-<date>.log
set -uo pipefail

MODE=${1:---check}
STACKS="home-assistant-stack immich homepage syncthing"
EXPECTED="homeassistant matter-server whisper immich_server immich_machine_learning immich_postgres immich_redis homepage syncthing"
MATTER_PROBE=light.kori_lamppu   # a Matter entity that should always be reachable
T=$(cat /home/legion/.ha_token)
LOGDIR=/home/legion/update-logs; mkdir -p "$LOGDIR"
LOG="$LOGDIR/update-$(date +%F-%H%M).log"
PROBLEMS=()

say()    { echo "$*" | tee -a "$LOG"; }
notify() { curl -sf -m 20 -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
             -d "{\"title\":\"$1\",\"message\":\"$(echo "$2" | tr '"\\\n' "'/ " | head -c 450)\"}" \
             http://localhost:8123/api/services/notify/mobile_app_phone >/dev/null; }
ha_version() { curl -s -m 5 -H "Authorization: Bearer $T" http://localhost:8123/api/config \
             | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "?"; }
gh_latest()  { gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null || echo "?"; }

# Images a stack's containers run vs. what the registry has now (no changes made).
check_images() {
  for s in $STACKS; do
    ( cd /home/legion/$s && docker compose config --images ) 2>/dev/null
  done | sort -u | while read -r img; do
    cur=$(docker image inspect -f '{{index .RepoDigests 0}}' "$img" 2>/dev/null | cut -d@ -f2)
    new=$(docker buildx imagetools inspect "$img" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"')
    if [ -z "$new" ]; then echo "  ?        $img (registry not reachable)"
    elif [ "$cur" = "$new" ]; then echo "  current  $img"
    else echo "  UPDATE   $img"; fi
  done
}

report_pending() {
  say "== Pending ($(date '+%F %T'))"
  sudo -n /usr/bin/apt update >/dev/null 2>&1
  n=$(apt list --upgradable 2>/dev/null | grep -vc Listing)
  say "apt: $n upgradable"; apt list --upgradable 2>/dev/null | grep -v Listing | cut -d/ -f1 | sed 's/^/  /' | tee -a "$LOG"
  say "Home Assistant: running $(ha_version), latest release $(gh_latest home-assistant/core)"
  say "matterjs-server (pinned): running $(docker inspect -f '{{.Config.Image}}' matter-server | cut -d: -f2), latest release $(gh_latest matter-js/matterjs-server)"
  say "Immich: latest release $(gh_latest immich-app/immich) (compose tracks the v3 tag)"
  say "Images:"; check_images | tee -a "$LOG"
  [ -f /var/run/reboot-required ] && say "A reboot is required (kernel/libc update installed earlier)."
}

health_check() {
  say "== Health check"
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Authorization: Bearer $T" http://localhost:8123/api/)
    [ "$code" = 200 ] && break; sleep 10
  done
  sleep 60   # let healthchecks settle
  [ "$code" = 200 ] && say "HA API: OK ($(ha_version))" || { say "HA API: FAILED ($code)"; PROBLEMS+=("HA API $code"); }
  for c in $EXPECTED; do
    st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
    say "  $c: $st"
    case $st in running|running/healthy) ;; *) PROBLEMS+=("$c $st");; esac
  done
  ms=$(curl -s -m 5 -H "Authorization: Bearer $T" http://localhost:8123/api/states/$MATTER_PROBE \
       | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null || echo "?")
  case $ms in on|off) say "Matter: $MATTER_PROBE is $ms (reachable through matter-server)";;
              *) say "Matter: $MATTER_PROBE is $ms"; PROBLEMS+=("matter: $MATTER_PROBE $ms");; esac
  for u in $(systemctl --failed --no-legend --plain | awk '{print $1}'); do PROBLEMS+=("failed: $u"); done
}

if [ "$MODE" = "--check" ]; then
  report_pending
  say "(check only, nothing changed. Log: $LOG)"
  exit 0
fi
[ "$MODE" = "--apply" ] || { echo "usage: $0 [--check|--apply]"; exit 2; }

say "== Update run $(date '+%F %T')"
report_pending
BEFORE_HA=$(ha_version)

# 1. Backup first. Refuse to continue without it.
mountpoint -q /mnt/backup || { say "ABORT: /mnt/backup not mounted"; notify "legion update aborted" "/mnt/backup not mounted"; exit 1; }
say "== restic backup"
START=$(date '+%F %T')
if ! systemctl --user start backup.service; then
  say "ABORT: backup failed"; notify "legion update aborted" "backup.service failed"; exit 1
fi
journalctl --user -u backup.service --since "$START" --no-pager -o cat | grep -E 'snapshot .* saved' | tail -1 | tee -a "$LOG"

# 2. OS packages, Docker included (upgrading docker-ce restarts every container).
# sudoers only allows exact apt forms plus "apt install *", so upgrade via install --only-upgrade
# (that form accepts --force-confold, which keeps locally edited config files without prompting).
say "== apt upgrade"
sudo -n /usr/bin/apt update >>"$LOG" 2>&1 || PROBLEMS+=("apt update failed")
PKGS=$(apt list --upgradable 2>/dev/null | grep -v Listing | cut -d/ -f1 | tr '\n' ' ')
if [ -n "$PKGS" ]; then
  say "upgrading: $PKGS"
  if ! sudo -n /usr/bin/apt install --only-upgrade -y -o Dpkg::Options::=--force-confdef \
         -o Dpkg::Options::=--force-confold $PKGS >>"$LOG" 2>&1; then
    PROBLEMS+=("apt upgrade failed (see log)")
  fi
  left=$(apt list --upgradable 2>/dev/null | grep -vc Listing)
  [ "$left" -gt 0 ] && say "still upgradable after run: $left (held back or needs new packages)"
fi
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 5; done

# 3. Containers: pull and recreate the ones whose image changed.
for s in $STACKS; do
  say "== $s"
  ( cd /home/legion/$s && docker compose pull -q && docker compose up -d --remove-orphans ) >>"$LOG" 2>&1 \
    || PROBLEMS+=("$s: pull/up failed")
done

# 4. Check everything came back.
health_check

# 5. Remove image layers that have been unused for 30+ days (last month's stay for rollback).
docker image prune -f --filter until=720h >>"$LOG" 2>&1

[ -f /var/run/reboot-required ] && say "Reboot required to finish (ask before rebooting)."
AFTER_HA=$(ha_version)
say "== Done: ${#PROBLEMS[@]} problem(s)"; for p in "${PROBLEMS[@]}"; do say "  - $p"; done
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  notify "legion updated: all OK" "HA $BEFORE_HA -> $AFTER_HA, all containers up. Log: $LOG"
else
  notify "legion update: ${#PROBLEMS[@]} problem(s)" "$(printf '%s; ' "${PROBLEMS[@]}") Log: $LOG"
  exit 1
fi
