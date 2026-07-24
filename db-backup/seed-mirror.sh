#!/bin/bash
# ONE-TIME seed of the second-disk backup mirror.  RUN WITH SUDO:
#
#     sudo /home/dean/btg/ops/db-backup/seed-mirror.sh
#
# WHY THIS NEEDS SUDO AND NOTHING ELSE DOES:
# /var/lib/postgresql (the mount point of nvme0n1p2, the DB drive) is owned
# postgres:postgres 0755, so the `dean` user cannot create a directory there.
# The nightly backup job runs as root and creates the mirror directory itself,
# so from tonight's 03:30 run onward no sudo is involved. This script only
# exists so the mirror is populated NOW instead of after the next run, and so
# the six dumps already on disk get their second copy.
#
# It is safe to re-run. It copies, never deletes source files, and never
# touches Postgres, any database, or any systemd unit.
set -euo pipefail

BACKUP_DIR=/home/dean/btg/db-backups
MIRROR_DIR=/var/lib/postgresql/btg-db-backups

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root:  sudo $0" >&2
  exit 1
fi

echo "== seeding second-disk mirror =="
mkdir -p "$MIRROR_DIR"
chown dean:dean "$MIRROR_DIR"
chmod 700 "$MIRROR_DIR"

pdev=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $1}')
mdev=$(df -P "$MIRROR_DIR" | awk 'NR==2 {print $1}')
echo "primary : $BACKUP_DIR  -> $pdev"
echo "mirror  : $MIRROR_DIR  -> $mdev"
if [ "$pdev" = "$mdev" ]; then
  echo "ERROR: both paths are on the SAME device ($mdev). Aborting — that is not a mirror." >&2
  exit 1
fi

copied=0
for src in "$BACKUP_DIR"/btg-*.dump "$BACKUP_DIR"/globals-*.sql; do
  [ -e "$src" ] || continue
  dst="$MIRROR_DIR/$(basename "$src")"
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
    echo "  already mirrored: $(basename "$src")"
    continue
  fi
  echo "  copying: $(basename "$src")"
  cp -f "$src" "$dst.partial"
  mv -f "$dst.partial" "$dst"
  chown dean:dean "$dst"
  chmod 600 "$dst"
  copied=$((copied + 1))
done

echo "== verifying mirror byte-for-byte =="
fail=0
for src in "$BACKUP_DIR"/btg-*.dump "$BACKUP_DIR"/globals-*.sql; do
  [ -e "$src" ] || continue
  dst="$MIRROR_DIR/$(basename "$src")"
  if cmp -s "$src" "$dst"; then
    echo "  OK   $(basename "$src")"
  else
    echo "  FAIL $(basename "$src")"
    fail=1
  fi
done

echo
echo "== newest mirrored dump: full pg_restore read =="
newest=$(ls -1t "$MIRROR_DIR"/btg-*.dump 2>/dev/null | head -1 || true)
if [ -n "$newest" ]; then
  if pg_restore -f /dev/null "$newest"; then
    echo "  OK   $(basename "$newest") reads end-to-end from the mirror"
  else
    echo "  FAIL $(basename "$newest") is not readable from the mirror"
    fail=1
  fi
fi

echo
df -h "$BACKUP_DIR" "$MIRROR_DIR"
echo
echo "copied $copied file(s); mirror now holds $(ls -1 "$MIRROR_DIR"/btg-*.dump 2>/dev/null | wc -l) dump(s)"
[ "$fail" -eq 0 ] && echo "SEED COMPLETE — second copy is live on $mdev" || echo "SEED FINISHED WITH FAILURES (see above)"
exit "$fail"
