#!/bin/bash
# Startup script for the short-lived Linux helper VM that backup.ps1 -Files creates.
# It mounts a copy of the Windows disk (made from a snapshot) read-only and syncs your folders to
# Cloud Storage: every user profile under C:\Users, C:\work and C:\ProgramData\rdp-autosuspend.
# Progress is reported in guest attribute backup/status; backup.ps1 waits for "done" and deletes the VM.
set -uo pipefail

MD=http://metadata.google.internal/computeMetadata/v1/instance
report() {
  echo "backup-helper: $1"
  curl -sf -X PUT -H "Metadata-Flavor: Google" --data "$1" "$MD/guest-attributes/backup/status" >/dev/null || true
}
trap 'report "failed at line $LINENO"; exit 1' ERR
set -e

DEST=$(curl -sf -H "Metadata-Flavor: Google" "$MD/attributes/dest")

report "installing ntfs-3g"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ntfs-3g >/dev/null

# The Windows volume is the largest NTFS partition on the attached disk.
report "mounting the Windows disk"
DISK=$(readlink -f /dev/disk/by-id/google-src)
PART=$(lsblk -lnbpo NAME,FSTYPE,SIZE "$DISK" | awk '$2=="ntfs" {print $3, $1}' | sort -n | tail -1 | cut -d' ' -f2)
mkdir -p /mnt/win
ntfs-3g -o ro "$PART" /mnt/win

# Regenerable or huge folders that aren't worth paying to store and download.
EXCLUDE='(^|.*/)(node_modules|\.next|__pycache__|\.venv|\.cache)/.*|^AppData/Local/(Temp|npm-cache|pip/cache|Packages|Microsoft/Windows/INetCache|Microsoft/Edge/User Data/.*Cache.*|Google/Chrome/User Data/.*Cache.*)/.*|^(NTUSER|ntuser)\..*'

FOLDERS=()
for u in /mnt/win/Users/*/; do
  name=$(basename "$u")
  case "$name" in Default|"Default User"|Public|"All Users") continue ;; esac
  FOLDERS+=("Users/$name")
done
[ -d /mnt/win/work ] && FOLDERS+=("work")
[ -d /mnt/win/ProgramData/rdp-autosuspend ] && FOLDERS+=("ProgramData/rdp-autosuspend")

errors=0
for f in "${FOLDERS[@]}"; do
  report "syncing C:/$f ($(du -sh --apparent-size "/mnt/win/$f" 2>/dev/null | cut -f1))"
  # Mirror (deleted files are removed here too; the bucket keeps old versions for 30 days).
  if ! gcloud storage rsync -r --ignore-symlinks --delete-unmatched-destination-objects \
      --exclude="$EXCLUDE" "/mnt/win/$f" "$DEST/$f" 2>&1 | tail -5; then
    errors=$((errors + 1))
  fi
done

total=$(gcloud storage du -s "$DEST" 2>/dev/null | awk '{printf "%.1f GB", $1/1e9}')
if [ "$errors" -eq 0 ]; then report "done: ${FOLDERS[*]} ($total in bucket)"; else report "done with $errors folder errors ($total in bucket)"; fi
