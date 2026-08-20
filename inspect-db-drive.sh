#!/usr/bin/env bash
# READ-ONLY inspection of /dev/nvme0n1p2 — mounts read-only, lists, unmounts.
# No writes, no formatting. Run:  sudo bash ~/btg/ops/inspect-db-drive.sh
set -euo pipefail
D=/dev/nvme0n1p2
T=$(mktemp -d)
mount -o ro "$D" "$T"
echo "=== filesystem usage (how much data is actually on it) ==="
df -h "$D" | tail -1
echo
echo "=== top-level listing ==="
ls -la "$T"
echo
echo "=== total entries (recursive) ==="
find "$T" -mindepth 1 | wc -l
echo
echo "=== up to 300 paths (relative) ==="
( cd "$T" && find . -mindepth 1 | head -300 )
umount "$T"; rmdir "$T"
echo
echo "=== done (read-only, nothing changed) ==="
