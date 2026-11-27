# legion: home server setup

How the home server `legion` is built, what runs on it, and how to maintain and rebuild it.
The config files in this repo are copies of the live ones, with secrets removed (see [What is not in this repo](#what-is-not-in-this-repo)).

Last updated: 2026-11-10.

## Architecture at a glance

A single always-on Debian laptop acts as a home server. Everything is declared in Docker Compose or systemd units, so the whole machine can be rebuilt from this repo plus a restic backup.

```
                 LAN clients (laptop, phone, TV)
                              |
   +--------------------------+---------------------------+
   |  legion: Debian 12, wired, no cloud dependency       |
   |                                                      |
   |  Docker Compose stacks          Native / systemd     |
   |  - Home Assistant + Matter      - Ollama (GPU)       |
   |    + Whisper (voice)            - Glances monitor    |
   |  - Immich (photos, Postgres)    - restic backup timer|
   |  - Homepage dashboard           - health check +     |
   |  - Syncthing                      phone alerts       |
   +------------------+-----------------------------------+
                      | nightly 03:00, restic (encrypted, deduplicated)
                      v
              second NVMe: /mnt/backup
```

- **Declarative:** four Compose stacks plus systemd user units; configs live in this repo.
- **Backed up:** nightly encrypted restic snapshots to a separate disk, with retention, integrity checks and restore tests.
- **Observable:** Glances, SMART monitoring, a post-reboot health report and phone alerts through Home Assistant when a job fails.
- **Hardened by habit:** secrets kept out of git, automatic security updates, least-privilege sudo allow-list.

## Contents

- [Hardware](#hardware)
- [Services](#services)
- [Storage](#storage)
- [Backups](#backups)
- [Battery](#battery)
- [Access and permissions](#access-and-permissions)
- [Maintenance](#maintenance)
- [Rebuild from scratch](#rebuild-from-scratch)
- [Known gaps / to do](#known-gaps--to-do)
- [Repo layout](#repo-layout)
- [What is not in this repo](#what-is-not-in-this-repo)

## Hardware

A Lenovo Legion 5 15ACH6 laptop, running headless with the lid closed (`HandleLidSwitch=ignore`).

| Part | Detail |
|---|---|
| CPU | AMD Ryzen 5 5600H (6 cores / 12 threads) |
| GPU | NVIDIA RTX 3050 Ti Laptop (driver 535), used by Ollama |
| RAM | 16 GB |
| Disk 1 | Samsung 256 GB NVMe (`nvme1n1`): system, Docker, all data |
| Disk 2 | WD SN730 512 GB NVMe (`nvme0n1`): backups only, `/mnt/backup` |
| Network | Wired `eno1`, LAN IP **192.168.1.X**. Router: OpenWrt at 192.168.1.X |
| Battery | 60 Wh, held at about 60% by Conservation Mode (see [Battery](#battery)) |
| OS | Debian 12 (bookworm), kernel 6.1, Docker 29 with Compose |

## Services

Everything except SSH, Ollama, Glances, Apache and raspotify runs in Docker Compose. Each stack lives in its own folder under `/home/legion/<stack>/`. The compose files are in [`stacks/`](stacks).

| Service | URL / port | How it runs | Purpose |
|---|---|---|---|
| Home Assistant | http://192.168.1.X:8123 | `home-assistant-stack`, host network | Home automation. Controls real devices |
| Matter Server | :5580 (ws + dashboard) | `home-assistant-stack`, host network | Matter controller for HA (IKEA DIRIGERA etc.). [matterjs-server](https://github.com/matter-js/matterjs-server) 1.6.0 since 2026-11-25 |
| Whisper | :10300 | `home-assistant-stack` | Speech-to-text for HA voice (`small-int8`, English) |
| Immich | http://192.168.1.X:2283 | `immich` (server, ML, Postgres, Valkey) | Photo library |
| Homepage | http://192.168.1.X:3000 | `homepage` | Dashboard linking every service |
| Syncthing | http://192.168.1.X:8384 (GUI), :22000 | `syncthing`, host network | File sync (`~/syncthing/vaults`) |
| Ollama | :11434 | system service `ollama` | Local LLM runtime on the GPU (no models installed since 2026-11-10) |
| Glances | http://192.168.1.X:61208 | user service `glances-web` | System monitor |
| Apache | (off) | system service, **stopped and disabled 2026-11-10** | Was only the Debian default page |
| raspotify | :4070 (zeroconf) | system service | Spotify Connect speaker. Port pinned with `LIBRESPOT_ZEROCONF_PORT=4070` in `/etc/raspotify/conf` |
| SSH | :22 | system service | Remote shell, keys only ([`10-keys-only.conf`](system/etc/ssh/sshd_config.d/10-keys-only.conf)) |
| Claude Code | n/a | user service `claude-rc` | Remote-control admin session (claude.ai / mobile app) |

Home Assistant's built-in go2rtc also uses 127.0.0.1:18554 (RTSP) and :18555 (WebRTC).

All the ports above listen on every interface. Since 2026-11-25 `ufw` filters what the LAN can reach (current rules: [`system/ufw-status.txt`](system/ufw-status.txt)):

- Default: deny incoming, allow outgoing. Blocked packets are logged (`journalctl -k | grep 'UFW BLOCK'`).
- From the LAN only (192.168.1.X/24, IPv6 ULA `fc00::/7`, link-local `fe80::/10`): TCP 22, 8123, 5580, 5540, 8384, 22000, 61208, 18555, 4070, 2283, 3000, 10300, and all UDP. UDP is left open on the LAN because Matter, Thread, mDNS and SSDP use random ports. The phone's VPN subnet `10.0.100.0/24` gets the same TCP ports and all UDP (without it the HA app shows "Connection lost" whenever the phone VPN is on).
- Docker networks (172.16.0.0/12) may reach host services (Homepage widgets query HA and Glances).
- Ollama (:11434) is not opened to the LAN.
- Caveat: ports published by Docker (2283, 3000, 10300) bypass ufw, because Docker writes its own iptables rules. They are listed anyway, so the rules match the intent.

### Data folders

| Path | Contents | Backed up |
|---|---|---|
| `~/homeassistant` | HA config, automations, dashboards, history DB | yes (minus `deps/`, logs) |
| `~/matter-server` | Matter fabric data. **Losing it means re-pairing every Matter device** | yes |
| `~/immich/library` | Photos (`library/`, `upload/`), nightly DB dumps (`backups/`) | yes (minus `thumbs/`, `encoded-video/`) |
| `~/immich/postgres` | Live Immich database | no, covered by the nightly dumps |
| `~/syncthing/{config,vaults}` | Syncthing config and synced data | yes |
| `~/homepage/config` | Dashboard config | yes |
| `~/whisper-data` | Downloaded models | no, re-downloadable |

## Storage

```
nvme1n1 (Samsung 256 GB)
├─ p1  512M  vfat   /boot/efi
├─ p2  237G  ext4   /          (system + Docker + all service data)
└─ p3  977M  swap   (+ /swapfile)

nvme0n1 (WD SN730 512 GB)   whole-disk ext4, label "backup", no partition table
└─ /mnt/backup   restic repository in /mnt/backup/restic
```

The fstab line for the backup disk is in [`system/etc/fstab.backup-line`](system/etc/fstab.backup-line). It uses `nofail`, so the server still boots if this disk dies.

## Backups

Backups use restic, run in a container (`restic/restic:0.18.1`), to the second NVMe.

- **Schedule:** every night at 03:00 via the user timer [`backup.timer`](system/systemd-user/backup.timer). That's after Immich writes its own DB dump at 02:00.
- **HA's own backup:** HA writes a consistent backup (config + database) to `~/homeassistant/backups/` daily at 02:30, keeping 3. restic picks it up at 03:00. Restore it in HA's onboarding screen ("Restore from backup") or under Settings → System → Backups.
- **Script:** [`backup/run-backup.sh`](backup/run-backup.sh). It skips the run if `/mnt/backup` isn't mounted.
- **Retention:** 7 daily, 4 weekly, 6 monthly snapshots. Every Sunday it runs `restic check --read-data-subset=5%`.
- **Encryption:** the repository password is in `~/backup/restic-password` (not in this repo). **Keep a copy of it somewhere off the server.** Without it the backups can't be read.
- **Size:** the first snapshot was 42.7 GB and took about 2 minutes.
- **Failure alerts:** if the backup fails (including when `/mnt/backup` isn't mounted), `OnFailure=` starts [`backup-failure-notify@.service`](system/systemd-user/backup-failure-notify@.service), which runs [`backup/notify-failure.sh`](backup/notify-failure.sh). That script sends a push notification to the phone through HA (`notify.mobile_app_phone`), using the token in `~/.ha_token`. Test it: `systemctl --user start backup-failure-notify@test.service`.

Common commands:

```bash
# Shorthand for running restic against the repo
R='docker run --rm --user root -v /mnt/backup/restic:/repo -v /home/legion/backup/restic-password:/pw:ro -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw'

$R restic/restic:0.18.1 snapshots                 # list snapshots
journalctl --user -u backup.service -n 50          # last run's log
systemctl --user list-timers backup.timer          # next run
systemctl --user start backup.service              # run now

# Restore one path from the latest snapshot into /mnt/backup/restore
$R -v /mnt/backup/restore:/out restic/restic:0.18.1 \
   restore latest --target /out --include /home/legion/homeassistant
```

### Restoring Immich

1. Restore `~/immich` (the library and `docker-compose.yml`). Recreate `.env` from the password manager, or from `example.env` with a new DB password.
2. Start only the database: `docker compose up -d database`.
3. Load the newest dump from `library/backups/`, following Immich's [restore guide](https://docs.immich.app/administration/backup-and-restore).
4. Run `docker compose up -d`. Immich regenerates thumbnails and transcoded videos on its own.

## Battery

The battery acts as a built-in backup power supply, so it is kept at about 60% to slow down wear.

- Lenovo **Conservation Mode** is on: `/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode` = `1`.
- It stays on after a reboot because of [`system/etc/tmpfiles.d/battery-conservation.conf`](system/etc/tmpfiles.d/battery-conservation.conf).
- Seeing "Not charging" below 100% while plugged in is normal.
- Check it: `cat /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode`.
- Battery health on 2026-11-08: 160 cycles, 55.5 of 60 Wh.

## Access and permissions

- The user is `legion`, with linger enabled so its user services start at boot.
- `legion` is in the `docker` group. That is effectively root access.
- `sudo` asks for a password, except for a short allow-list (apt updates, systemctl service control, smartctl, journalctl, mount/umount and the battery toggle), called by full path with `sudo -n`. The sudoers file itself is not published.
- A Claude Code Remote Control session runs as the user service [`claude-rc`](system/systemd-user/claude-rc.service).

## Maintenance

```bash
# OS updates
sudo -n /usr/bin/apt update && sudo -n /usr/bin/apt upgrade -y

# Update one Docker stack (Immich and HA: read release notes first)
cd ~/<stack> && docker compose pull && docker compose up -d

# Validate HA config before restarting it
docker exec homeassistant python -m homeassistant --script check_config -c /config

# Health
docker ps                                  # all containers up/healthy?
df -h / /mnt/backup                        # disk space
journalctl --user -u backup.service -n 20  # last backup
```

**Planned reboots:** first run `systemctl --user enable post-reboot-check.service`. After the next boot, [`scripts/post-reboot-check.sh`](scripts/post-reboot-check.sh) waits for HA and checks the containers, services, failed units, the backup mount, battery Conservation Mode, the GPU and the running kernel. It writes `~/post-reboot-report.txt`, pushes a summary to the phone through HA, and then disables itself.


## Rebuild from scratch

1. Install Debian 12 and create the user `legion`. Install Docker and the Compose plugin, add `legion` to the `docker` group, and run `loginctl enable-linger legion`.
2. Set `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`.
3. Mount the backup disk: add the line from `system/etc/fstab.backup-line` to `/etc/fstab`, then run `mkdir /mnt/backup && mount -a`.
4. Restore the data folders from restic (see [Backups](#backups)). This brings back `~/homeassistant`, `~/matter-server`, `~/immich`, `~/syncthing`, `~/homepage`, the compose files and `~/backup`.
5. Recreate the secrets that aren't backed up as plain files: `~/immich/.env` and `~/backup/restic-password` (both from the password manager). `~/homeassistant/secrets.yaml` is in the restic backup.
6. Put your SSH public key in `~legion/.ssh/authorized_keys` first (`10-keys-only.conf` turns password logins off). Copy the files from `system/etc/` and `system/systemd-user/` into place, then run `systemctl --user enable --now backup.timer glances-web`.
7. Install `ufw` and recreate the rules listed in `system/ufw-status.txt` (see [Services](#services) for the commands' shape: `ufw allow proto tcp from 192.168.1.X/24 to any port <p>`), then `ufw enable`. Set `LIBRESPOT_ZEROCONF_PORT=4070` in `/etc/raspotify/conf`.
8. Install Ollama (`curl -fsSL https://ollama.com/install.sh | sh`), add `override.conf`, and pull any models you want (`ollama pull <model>`).
9. Start each stack with `cd ~/<stack> && docker compose up -d`.
10. Check: Homepage at :3000 should show every service as up.

## Known gaps / to do

- [ ] **No off-site backup.** Both copies are in the same laptop. Add a second restic repository (Backblaze B2, or the t470s).
- [x] Firewall: `ufw` enabled 2026-11-25, LAN-only, only the ports in use (see [Ports](#services)). Off switch: `sudo -n /usr/sbin/ufw disable`.
- [ ] Ollama listens on `0.0.0.0` with no authentication. ufw now blocks it from the LAN; binding it to localhost would be cleaner.
- [x] SSH is keys only since 2026-11-25 (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`).
- [x] Automatic security updates: `unattended-upgrades` enabled 2026-11-10 via [`system/etc/apt/apt.conf.d/20auto-upgrades`](system/etc/apt/apt.conf.d/20auto-upgrades) (default origins: Debian and Debian-Security only, so Docker's repo is never auto-upgraded; no automatic reboots). Log: `/var/log/unattended-upgrades/`.
- [x] Removed the unsigned Espressif apt source (2026-11-10). Backup copy: `/etc/apt/espressif-eim.list.bak-20261110`. `~/.espressif` and the `eim` package are still installed.
- [x] 2026-11-10: all apt updates installed, Docker 29.9.3 included, then rebooted into kernel 6.1.0-54. This was also the first reboot test of Conservation Mode: it stayed on. Post-reboot check: 0 problems.
- [x] ~~`eno1` set up both by ifupdown and NetworkManager~~ Fixed 2026-11-25: `eno1` is managed only by NetworkManager (`system/etc/NetworkManager/system-connections/eno1.nmconnection`: DHCPv4, IPv6 auto, WoL magic); `/etc/network/interfaces` has only `lo`. Old config backed up in `/etc/network/backup-20261125/`. `scripts/network-rollback-check.sh` (one-shot user unit) rolls it back and reboots if `eno1` has no network within 4 min of boot.
- [x] RTC switched from local time (Windows leftover) to UTC on 2026-11-25 (`timedatectl set-local-rtc 0`). The clock no longer runs 1 h fast at boot.
- [x] HA shut down uncleanly on reboot (Docker's 10 s stop timeout): `stop_grace_period: 60s` added 2026-11-25.
- [x] HA Bluetooth: `hci0` was rfkill soft-blocked at boot (HA misreported it as missing capabilities). Fixed 2026-11-25 with [`80-bluetooth-unblock.rules`](system/etc/udev/rules.d/80-bluetooth-unblock.rules).
- [x] Cleanup 2026-11-25: removed `~/.espressif` (unused ESP-IDF toolchain), pip/Homebrew caches and 18 autoremovable packages, ~13 GB.
- [x] Update routine: [`scripts/update-all.sh`](scripts/update-all.sh), run by hand monthly. `--check` (default) lists pending apt packages, image updates and HA/Immich/matterjs-server versions; `--apply` backs up with restic first, runs `apt full-upgrade` (Docker included), pulls and recreates every stack, health-checks and notifies the phone. Logs in `~/update-logs/`.
- [x] Matter: migrated 2026-11-25 from the archived `python-matter-server` to [`matterjs-server`](https://github.com/matter-js/matterjs-server) 1.6.0 (pinned). Same data dir and WebSocket; the DIRIGERA kept its pairing.
- [x] First `update-all.sh --apply` run 2026-11-25: HA 2026.10.2 → 2026.11.3, Immich 3.3.6 → 3.4.2, Docker 29.9.3 → 29.10.1, Homepage/Syncthing/Whisper images. 0 problems.
- [x] Docker log limits: [`system/etc/docker/daemon.json`](system/etc/docker/daemon.json) (json-file, 3 × 10 MB per container), 2026-11-25.
- [ ] Debian 12 is on LTS-only security support; plan the upgrade to Debian 13.
- [ ] No uptime alerts. Options: Uptime Kuma, or HA notifications. (Backup failures do alert, see [Backups](#backups).)
- [x] Power cuts: [`scripts/power-watch.sh`](scripts/power-watch.sh) (user unit `power-watch`) notifies the phone when mains is lost/restored and powers off cleanly at ≤15% battery. The machine then stays off until the power button is pressed.
- [x] Drive health: `smartmontools` installed 2026-11-10 (`smartd` running). Both NVMe drives PASSED, 1–2% wear, no media errors. Check: `sudo -n /usr/sbin/smartctl -H -A /dev/nvme0n1`. smartd's warnings only go to the journal, so nothing alerts on them yet.
- [x] HA's own backups: daily at 02:30 to `~/homeassistant/backups` (DB included, unencrypted, 3 copies), so the 03:00 restic run always has a consistent copy of the database. Since 2026-11-25.

## Repo layout

```
stacks/            docker compose files (+ Homepage config, Immich example.env)
homeassistant/     HA YAML config (configuration, automations, dashboard)
system/etc/        tmpfiles (battery), Ollama override, fstab line
system/systemd-user/  backup timer/service, glances-web, claude-rc
backup/            run-backup.sh
docs/server-notes.md  full admin notes and change history (CLAUDE.md points here)
scripts/ha-get     read-only GET helper for the local HA REST API
```

## What is not in this repo

These are never committed: `~/homeassistant/secrets.yaml`, HA's `.storage/` (tokens, device registry), `~/immich/.env`, the restic password, `~/.ssh`, Claude/GitHub credentials, and photos or other personal data. The Homepage router widget password is replaced with `REDACTED`.

---
This is a sanitized public mirror of a private repo: LAN addresses, device IDs and personal details are replaced with placeholders, and some host-specific files are omitted.
