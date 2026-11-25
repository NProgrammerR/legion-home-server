#!/bin/bash
# One-shot health check after a reboot. Waits for services, writes ~/post-reboot-report.txt,
# pushes a summary to the phone via Home Assistant, then disables its own unit.
# Re-arm before a planned reboot: systemctl --user enable post-reboot-check.service
OUT=/home/legion/post-reboot-report.txt
EXPECTED="homeassistant matter-server whisper immich_server immich_machine_learning immich_postgres immich_redis homepage syncthing"
dk() { sg docker -c "$*"; }

# Wait up to 10 min for HA's API (it comes up last) so the notification can be sent.
T=$(cat /home/legion/.ha_token)
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Authorization: Bearer $T" http://localhost:8123/api/)
  [ "$code" = 200 ] && break
  sleep 10
done
sleep 60   # give healthchecks time to settle

PROBLEMS=()
{
  echo "Post-reboot check, $(date '+%F %T')"
  echo "Kernel: $(uname -r)   Uptime: $(uptime -p)"
  echo "eno1: $(ip -4 -br addr show eno1 | awk '{print $3}')"
  newest=$(ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)
  [ "$(uname -r)" = "$newest" ] || PROBLEMS+=("running kernel $(uname -r), newest installed is $newest")
  echo

  [ "$code" = 200 ] && echo "HA API: OK" || { echo "HA API: FAILED ($code)"; PROBLEMS+=("HA API $code"); }

  echo; echo "Containers:"
  dk "docker ps -a --format '{{.Names}}|{{.Status}}'" | sort | sed 's/|/  /'
  for c in $EXPECTED; do
    st=$(dk "docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' $c" 2>/dev/null)
    case "$st" in running|"running healthy"|"running ") ;; *) PROBLEMS+=("$c: ${st:-missing}");; esac
  done
  echo "Docker: $(dk "docker version --format '{{.Server.Version}}'")"

  echo; echo "Services:"
  for s in ssh ollama raspotify smartd NetworkManager docker; do
    a=$(systemctl is-active $s); echo "  $s: $a"; [ "$a" = active ] || PROBLEMS+=("$s $a")
  done
  for s in glances-web backup.timer; do
    a=$(systemctl --user is-active $s); echo "  $s (user): $a"; [ "$a" = active ] || PROBLEMS+=("$s $a")
  done

  echo; echo "Failed system units:"
  systemctl --failed --no-legend --plain | awk '{print "  "$1}'
  for u in $(systemctl --failed --no-legend --plain | awk '{print $1}'); do PROBLEMS+=("failed: $u"); done
  for u in $(systemctl --user --failed --no-legend --plain | awk '{print $1}'); do PROBLEMS+=("failed (user): $u"); done

  echo
  mountpoint -q /mnt/backup && echo "/mnt/backup: mounted" || { echo "/mnt/backup: NOT mounted"; PROBLEMS+=("/mnt/backup not mounted"); }
  cm=$(cat /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode 2>/dev/null)
  echo "Battery conservation_mode: $cm (battery $(cat /sys/class/power_supply/BAT0/capacity)%)"
  [ "$cm" = 1 ] || PROBLEMS+=("conservation_mode=$cm")
  g=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1)
  echo "GPU: $g"
  nvidia-smi >/dev/null 2>&1 || PROBLEMS+=("nvidia-smi failed")

  echo; echo "Problems: ${#PROBLEMS[@]}"
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
} > "$OUT" 2>&1

if [ ${#PROBLEMS[@]} -eq 0 ]; then
  TITLE="legion is back online: all OK"
  MSG="Kernel $(uname -r), 9/9 containers up, battery conservation on. Ask Claude to read ~/post-reboot-report.txt for details."
else
  TITLE="legion is back online: ${#PROBLEMS[@]} problem(s)"
  MSG="$(printf '%s; ' "${PROBLEMS[@]}" | tr '"\\' "'/" | head -c 400) Ask Claude to read ~/post-reboot-report.txt"
fi
curl -sf -m 20 -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d "{\"title\":\"$TITLE\",\"message\":\"$MSG\"}" \
  http://localhost:8123/api/services/notify/mobile_app_phone >/dev/null

systemctl --user disable post-reboot-check.service
