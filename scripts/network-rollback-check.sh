#!/bin/bash
# One-shot boot check after the 2026-11-25 network change (eno1 moved to NetworkManager only).
# If eno1 has no working IPv4 + gateway within ~4 min, restore the old /etc/network config and
# NM keyfile from /etc/network/backup-20261125 and reboot. Disables itself either way.
LOG=~/network-rollback-check.log
exec >>"$LOG" 2>&1
echo "== $(date) boot check"
systemctl --user disable network-rollback-check.service
for i in $(seq 1 48); do
  if ip -4 addr show eno1 | grep -q 'inet ' && ping -c1 -W2 192.168.1.X >/dev/null; then
    echo "OK after $((i*5))s: $(ip -br -4 addr show eno1)"; exit 0
  fi
  sleep 5
done
echo "FAIL: no network on eno1, rolling back"
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker run --rm --user root --entrypoint sh -v /etc/network:/n -v /etc/NetworkManager/system-connections:/nm \
  rhasspy/wyoming-whisper:latest -c 'B=/n/backup-20261125; cp -a $B/interfaces /n/interfaces; cp -a $B/interfaces.d/. /n/interfaces.d/; cp -a $B/eno1.nmconnection /nm/eno1.nmconnection' \
  && echo "restored" || echo "restore FAILED"
sudo -n /usr/bin/systemctl start reboot.target
