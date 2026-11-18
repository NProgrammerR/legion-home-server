#!/bin/sh
# Nightly restic backup of legion's server data to the second NVMe (/mnt/backup).
# Runs restic in a container (no sudo on this host). Called by ~/.config/systemd/user/backup.service.
set -eu

REPO_DIR=/mnt/backup/restic
PW=/home/legion/backup/restic-password
IMAGE=restic/restic:0.18.1

# Refuse to run if the backup drive isn't mounted (would otherwise fill the system disk).
if ! mountpoint -q /mnt/backup; then
  echo "ERROR: /mnt/backup is not mounted; skipping backup" >&2
  exit 1
fi

restic() {
  sg docker -c "docker run --rm --user root --hostname legion \
    -v $REPO_DIR:/repo \
    -v $PW:/pw:ro \
    -v /home/legion:/home/legion:ro \
    -v /etc/fstab:/etc-host/fstab:ro \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw \
    $IMAGE $*"
}

restic backup --host legion --tag nightly --one-file-system \
  /home/legion/immich \
  /home/legion/homeassistant \
  /home/legion/home-assistant-stack \
  /home/legion/matter-server \
  /home/legion/syncthing \
  /home/legion/homepage \
  /home/legion/backup \
  /etc-host/fstab \
  --exclude /home/legion/immich/postgres \
  --exclude /home/legion/immich/library/thumbs \
  --exclude /home/legion/immich/library/encoded-video \
  --exclude /home/legion/backup/restic-password \
  --exclude /home/legion/homeassistant/deps \
  --exclude "'/home/legion/homeassistant/*.log*'"

restic forget --host legion --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# Sundays: verify repository integrity and re-read 5% of the stored data.
if [ "$(date +%u)" = 7 ]; then
  restic check --read-data-subset=5%
fi
