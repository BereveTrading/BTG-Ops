#!/bin/bash
# BTG nightly Postgres backup — runs as root (system timer), dumps the btg
# database and lands TWO copies on TWO different physical disks, so no single
# drive failure can take both the database and its backups.
#
#   PRIMARY  /home/dean/btg/db-backups          -> nvme1n1p2  (/, OS drive)
#   MIRROR   /var/lib/postgresql/btg-db-backups -> nvme0n1p2  (PG data drive)
#
# Outputs per run, in each location:
#   btg-YYYY-MM-DD.dump      pg_dump custom format (compressed, pg_restore-able)
#   globals-YYYY-MM-DD.sql   roles + grants (pg_dumpall --globals-only) — matters
#                            because prod grants were partly applied by hand
#
# Retention: keeps the newest 14 of each, in both locations; older are pruned.
#
# Verification: every run is read END TO END with `pg_restore -f /dev/null`,
# which decompresses every data block and fails on truncation or bit-rot.
# (The old check was `pg_restore --list`, which only reads the TOC header at the
# front of the file and returns in ~0.02s — it would happily pass a dump whose
# 900MB of data was garbage. The full read costs ~8s. Worth it.)
#
# NOTE: this is still a backup, not an offsite copy. Both disks are in the same
# box. See offsite-push.sh for the third copy.
set -euo pipefail

BACKUP_DIR=/home/dean/btg/db-backups
MIRROR_DIR=/var/lib/postgresql/btg-db-backups
KEEP=14
MIN_FREE_MB=5000

STAMP=$(date +%F)
DUMP="$BACKUP_DIR/btg-$STAMP.dump"
GLOBALS="$BACKUP_DIR/globals-$STAMP.sql"
LOG="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
exec >>"$LOG" 2>&1
echo "[$(date -Is)] backup start"

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

# Clear any .partial left behind by a previous crashed run. The prune globs
# below don't match *.partial, so without this they accumulate forever.
rm -f "$BACKUP_DIR"/*.partial

avail=$(free_mb "$BACKUP_DIR")
if [ "$avail" -lt "$MIN_FREE_MB" ]; then
  echo "[$(date -Is)] ABORT: only ${avail}MB free on $BACKUP_DIR (need ${MIN_FREE_MB}MB)"
  exit 1
fi

runuser -u postgres -- pg_dump -Fc --no-password btg >"$DUMP.partial"
mv "$DUMP.partial" "$DUMP"

runuser -u postgres -- pg_dumpall --globals-only --no-password >"$GLOBALS.partial"
mv "$GLOBALS.partial" "$GLOBALS"

# Full-archive verification: decompress every block. A dump that can't be read
# through to the end is not a backup.
if ! pg_restore -f /dev/null "$DUMP"; then
  echo "[$(date -Is)] VERIFY FAILED (full read) for $DUMP"
  exit 1
fi

chown dean:dean "$DUMP" "$GLOBALS"
chmod 600 "$DUMP" "$GLOBALS"

# Prune primary: keep newest $KEEP of each kind.
ls -1t "$BACKUP_DIR"/btg-*.dump     2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1t "$BACKUP_DIR"/globals-*.sql  2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "[$(date -Is)] backup ok: $(du -h "$DUMP" | cut -f1) $(basename "$DUMP")"

# ---------------------------------------------------------------------------
# Mirror to the second physical disk.
#
# This runs as root, so it creates and owns MIRROR_DIR itself — no sudo needed
# from anyone. Copies are written .partial then renamed, so a mirror that dies
# mid-copy never leaves a half-file that looks like a good backup.
#
# A mirror failure does NOT lose the primary dump (already written and verified
# above), but it DOES exit non-zero so systemd marks the unit failed — a
# silently-broken mirror is the exact failure mode this whole thing exists to
# prevent.
# ---------------------------------------------------------------------------
mirror_failed=0

if ! mkdir -p "$MIRROR_DIR"; then
  echo "[$(date -Is)] MIRROR FAILED: cannot create $MIRROR_DIR"
  mirror_failed=1
else
  chown dean:dean "$MIRROR_DIR"
  chmod 700 "$MIRROR_DIR"
  rm -f "$MIRROR_DIR"/*.partial

  mavail=$(free_mb "$MIRROR_DIR")
  if [ "$mavail" -lt "$MIN_FREE_MB" ]; then
    echo "[$(date -Is)] MIRROR FAILED: only ${mavail}MB free on $MIRROR_DIR"
    mirror_failed=1
  else
    for src in "$DUMP" "$GLOBALS"; do
      dst="$MIRROR_DIR/$(basename "$src")"
      if cp -f "$src" "$dst.partial" && mv -f "$dst.partial" "$dst"; then
        chown dean:dean "$dst"; chmod 600 "$dst"
      else
        echo "[$(date -Is)] MIRROR FAILED: copy of $(basename "$src")"
        rm -f "$dst.partial"
        mirror_failed=1
      fi
    done
  fi
fi

if [ "$mirror_failed" -eq 0 ]; then
  # Confirm the mirror really is on a different device than the primary.
  pdev=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $1}')
  mdev=$(df -P "$MIRROR_DIR" | awk 'NR==2 {print $1}')
  if [ "$pdev" = "$mdev" ]; then
    echo "[$(date -Is)] MIRROR WARNING: $MIRROR_DIR is on the SAME device ($mdev) as the primary — not a real second copy"
    mirror_failed=1
  else
    # Byte-for-byte check of the mirrored dump, then prune the mirror.
    if cmp -s "$DUMP" "$MIRROR_DIR/$(basename "$DUMP")"; then
      ls -1t "$MIRROR_DIR"/btg-*.dump    2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
      ls -1t "$MIRROR_DIR"/globals-*.sql 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
      echo "[$(date -Is)] mirror ok: $MIRROR_DIR ($mdev) <- primary ($pdev)"
    else
      echo "[$(date -Is)] MIRROR FAILED: byte comparison mismatch for $(basename "$DUMP")"
      mirror_failed=1
    fi
  fi
fi

# Best-effort offsite push. Absent/unconfigured credentials are NOT a backup
# failure — the script says so and returns 0 in that case. See offsite-push.sh.
OFFSITE=/home/dean/btg/ops/db-backup/offsite-push.sh
if [ -x "$OFFSITE" ]; then
  "$OFFSITE" || echo "[$(date -Is)] offsite push reported a problem (see above)"
fi

exit "$mirror_failed"
