#!/bin/bash
# BTG restore drill — proves the newest backup can actually be brought back.
#
#   ./restore-drill.sh                 # full drill: restore into a scratch DB (default)
#   ./restore-drill.sh --mode=archive  # quick: read the archive end-to-end, no DB
#   ./restore-drill.sh --file=/path/to/btg-2026-07-24.dump
#   ./restore-drill.sh --keep          # don't drop the scratch DB (inspect it yourself)
#
# WHAT "FULL" DOES
#   creates a throwaway database  btg_restoredrill_<timestamp>
#   CREATE EXTENSION timescaledb + timescaledb_pre_restore()
#   pg_restore the dump into it
#   timescaledb_post_restore()
#   counts what came back, prints it
#   DROPS the scratch database
#
# SAFETY (this touches production Postgres, so read this)
#   - refuses to target any database whose name is not btg_restoredrill_*
#   - never connects to, reads from, or writes to the live `btg` database
#   - never stops/restarts Postgres, never touches any systemd unit
#   - drops the scratch DB on exit, including on Ctrl-C or error (trap)
#   - runs pg_restore under nice/ionice so it yields to ingestd
#   - checks free space on the PG drive before starting
#   - the restore is I/O heavy (expect tens of GB written and a busy disk for
#     several minutes). Run it when the box is quiet — that is why the suggested
#     schedule is 04:30 on the 1st of the month, an hour after the nightly dump.
#
# SCHEDULING IT MONTHLY
#   Two files, then one command. As root:
#
#     /etc/systemd/system/btg-restore-drill.service
#       [Unit]
#       Description=BTG monthly restore drill
#       After=postgresql.service
#       [Service]
#       Type=oneshot
#       User=dean
#       ExecStart=/home/dean/btg/ops/db-backup/restore-drill.sh
#
#     /etc/systemd/system/btg-restore-drill.timer
#       [Unit]
#       Description=Run BTG restore drill monthly
#       [Timer]
#       OnCalendar=*-*-01 04:30:00
#       Persistent=true
#       [Install]
#       WantedBy=timers.target
#
#     sudo systemctl daemon-reload && sudo systemctl enable --now btg-restore-drill.timer
#
#   Output lands in the journal: journalctl -u btg-restore-drill.service
set -uo pipefail

BACKUP_DIR=/home/dean/btg/db-backups
MIRROR_DIR=/var/lib/postgresql/btg-db-backups
ENVFILE=/home/dean/btg/ops/btg-db.env
LOG=/home/dean/btg/ops/db-backup/restore-drill.log
MIN_FREE_MB=40000

MODE=full
DUMP=""
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --mode=*) MODE="${arg#*=}" ;;
    --file=*) DUMP="${arg#*=}" ;;
    --keep)   KEEP=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

exec > >(tee -a "$LOG") 2>&1
echo "=============================================================="
echo "[$(date -Is)] restore drill start (mode=$MODE)"

fail() { echo "[$(date -Is)] DRILL FAILED: $*"; exit 1; }

# --- pick the dump ----------------------------------------------------------
if [ -z "$DUMP" ]; then
  DUMP=$(ls -1t "$BACKUP_DIR"/btg-*.dump 2>/dev/null | head -1)
fi
[ -n "$DUMP" ] && [ -r "$DUMP" ] || fail "no readable dump found in $BACKUP_DIR"

echo "dump      : $DUMP"
echo "size      : $(stat -c%s "$DUMP") bytes ($(du -h "$DUMP" | cut -f1))"
echo "modified  : $(stat -c%y "$DUMP")"

age_days=$(( ( $(date +%s) - $(stat -c%Y "$DUMP") ) / 86400 ))
echo "age       : ${age_days} day(s)"
[ "$age_days" -gt 2 ] && echo "WARNING: newest dump is ${age_days} days old — is the nightly timer running?"

# --- mirror presence check --------------------------------------------------
mbase="$MIRROR_DIR/$(basename "$DUMP")"
if [ -r "$mbase" ]; then
  if cmp -s "$DUMP" "$mbase"; then
    echo "mirror    : OK, identical copy present on $(df -P "$MIRROR_DIR" | awk 'NR==2{print $1}')"
  else
    echo "mirror    : WARNING — $mbase exists but differs from the primary"
  fi
else
  echo "mirror    : WARNING — no second-disk copy at $mbase"
fi

# --- stage 1: full archive read (always) ------------------------------------
echo
echo "-- stage 1: full archive read (decompresses every block) --"
t0=$(date +%s)
pg_restore -f /dev/null "$DUMP" || fail "archive does not read end-to-end (truncated or corrupt)"
echo "PASS  read clean in $(( $(date +%s) - t0 ))s"

echo
echo "-- stage 2: table of contents --"
toc=$(mktemp) || fail "mktemp"
pg_restore --list "$DUMP" > "$toc" || fail "cannot list TOC"
echo "TOC entries      : $(grep -c ';' "$toc")"
echo "TABLE DATA items : $(grep -c 'TABLE DATA' "$toc")"
echo "extensions       : $(grep -c 'EXTENSION -' "$toc")"
grep -q 'EXTENSION - timescaledb' "$toc" || echo "WARNING: timescaledb extension not present in dump"
rm -f "$toc"

# --- globals ----------------------------------------------------------------
G=$(ls -1t "$BACKUP_DIR"/globals-*.sql 2>/dev/null | head -1)
if [ -n "${G:-}" ]; then
  echo
  echo "-- globals: $(basename "$G") --"
  roles=$(grep -c '^CREATE ROLE' "$G")
  echo "roles captured   : $roles"
  tail -3 "$G" | grep -q 'unrestrict\|--' \
    && echo "PASS  globals file ends cleanly (not truncated)" \
    || echo "WARNING: globals file may be truncated"
  [ "$roles" -ge 4 ] || echo "WARNING: only $roles roles — expected btg_ingest/btg_read/btg_dominance/postgres"
fi

if [ "$MODE" = "archive" ]; then
  echo
  echo "[$(date -Is)] DRILL PASSED (archive mode). NOTE: this proves the file is"
  echo "readable and complete. It does NOT prove it restores. Run without"
  echo "--mode=archive for the real thing."
  exit 0
fi
[ "$MODE" = "full" ] || fail "unknown mode '$MODE' (use full or archive)"

# --- stage 3: real restore into a scratch database --------------------------
echo
echo "-- stage 3: restore into a throwaway database --"

[ -r "$ENVFILE" ] || fail "cannot read $ENVFILE (need superuser DSN for createdb)"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
ADMIN_URL=${BTG_BACKFILL_DATABASE_URL:-}
[ -n "$ADMIN_URL" ] || fail "BTG_BACKFILL_DATABASE_URL not set in $ENVFILE"

SCRATCH="btg_restoredrill_$(date +%Y%m%d_%H%M%S)"
case "$SCRATCH" in
  btg_restoredrill_*) : ;;
  *) fail "refusing to use scratch name '$SCRATCH'" ;;
esac
[ "$SCRATCH" = "btg" ] && fail "refusing to touch the live btg database"

# Admin connections go to the maintenance DB, never to btg.
ADMIN_MAINT="${ADMIN_URL%/*}/postgres"
SCRATCH_URL="${ADMIN_URL%/*}/$SCRATCH"

free_mb=$(df -Pm /var/lib/postgresql | awk 'NR==2 {print $4}')
echo "free on PG drive : ${free_mb}MB"
[ "$free_mb" -ge "$MIN_FREE_MB" ] || fail "need at least ${MIN_FREE_MB}MB free to restore"

dropped=0
drop_scratch() {
  [ "$dropped" -eq 1 ] && return
  dropped=1
  if [ "$KEEP" -eq 1 ]; then
    echo "[$(date -Is)] --keep given: leaving scratch DB '$SCRATCH' in place."
    echo "               drop it yourself:  dropdb '$SCRATCH'"
    return
  fi
  echo "[$(date -Is)] dropping scratch database $SCRATCH"
  psql "$ADMIN_MAINT" -q -c "DROP DATABASE IF EXISTS \"$SCRATCH\" WITH (FORCE);" \
    || echo "WARNING: could not drop $SCRATCH — drop it by hand"
}
trap drop_scratch EXIT INT TERM

psql "$ADMIN_MAINT" -qtAc "SELECT 1" >/dev/null || fail "cannot connect to Postgres as admin"

echo "creating scratch database: $SCRATCH"
psql "$ADMIN_MAINT" -q -c "CREATE DATABASE \"$SCRATCH\";" || fail "createdb failed"

# TimescaleDB requires this exact dance around a pg_restore.
psql "$SCRATCH_URL" -q -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" \
  || fail "cannot create timescaledb extension in scratch DB"
psql "$SCRATCH_URL" -qtAc "SELECT timescaledb_pre_restore();" >/dev/null \
  || fail "timescaledb_pre_restore() failed"

# SINGLE-THREADED ON PURPOSE — do not add -j.
# A TimescaleDB dump carries the _timescaledb_catalog tables (hypertable,
# dimension, dimension_slice, chunk...) which have foreign keys between them.
# pg_restore -j loads table data in parallel and does not honour that ordering,
# so `dimension` and `dimension_slice` fail their FK checks, the catalog ends up
# empty, and you get a database that LOOKS restored — 7.8GB, millions of rows in
# the _hyper_*_chunk tables — but reports 0 hypertables and 0 rows in ohlcv,
# because without the catalog nothing is wired to its parent table.
# Verified on 2026-07-24: -j 2 fails exactly that way, single-threaded passes.
echo "restoring single-threaded (nice/ionice, yields to production)..."
errlog=$(mktemp)
t0=$(date +%s)
nice -n 19 ionice -c3 pg_restore --no-owner --no-acl \
     -d "$SCRATCH_URL" "$DUMP" 2>"$errlog"
prc=$?
elapsed=$(( $(date +%s) - t0 ))

psql "$SCRATCH_URL" -qtAc "SELECT timescaledb_post_restore();" >/dev/null \
  || echo "WARNING: timescaledb_post_restore() failed"

# pg_restore emits benign noise when the extension already exists. Count only
# what is not that.
# NOTE: `grep -c` prints 0 AND exits 1 when there are no matches, so every one
# of these needs `|| true` or the arithmetic below blows up under `set -u`.
total_err=$(grep -c '^pg_restore: error' "$errlog" 2>/dev/null || true)
benign=$(grep '^pg_restore: error' "$errlog" 2>/dev/null \
          | grep -ci 'already exists\|extension "timescaledb"' || true)
total_err=${total_err:-0}; benign=${benign:-0}
real_err=$(( total_err - benign ))

echo "restore exit     : $prc  (elapsed ${elapsed}s)"
echo "pg_restore errors: $total_err total, $benign benign, $real_err real"
if [ "$real_err" -gt 0 ]; then
  keptlog="/home/dean/btg/ops/db-backup/restore-drill-errors-$(date +%Y%m%d_%H%M%S).log"
  cp "$errlog" "$keptlog"
  echo "full error output kept at: $keptlog"
  echo "--- first 20 non-benign errors ---"
  grep '^pg_restore: error' "$errlog" | grep -vi 'already exists\|extension "timescaledb"' | head -20
fi

# --- stage 4: does the restored data look like a database? ------------------
echo
echo "-- stage 4: sanity checks on the restored database --"
tables=$(psql "$SCRATCH_URL" -qtAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
hyper=$(psql "$SCRATCH_URL" -qtAc "SELECT count(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "n/a")
dbsize=$(psql "$SCRATCH_URL" -qtAc "SELECT pg_size_pretty(pg_database_size('$SCRATCH'));")
echo "public tables    : $tables"
echo "hypertables      : $hyper"
echo "restored size    : $dbsize"

echo "row counts (largest relations):"
psql "$SCRATCH_URL" -qtA -F' | ' -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  WHERE n_live_tup > 0
  ORDER BY n_live_tup DESC
  LIMIT 10;" 2>/dev/null | sed 's/^/  /'

ohlcv=$(psql "$SCRATCH_URL" -qtAc "SELECT count(*) FROM public.ohlcv;" 2>/dev/null || echo 0)
echo "ohlcv rows       : $ohlcv"

rm -f "$errlog"

verdict=0
[ "$prc" -ne 0 ]        && { echo "FAIL: pg_restore exited $prc"; verdict=1; }
[ "$real_err" -gt 0 ]   && { echo "FAIL: $real_err real restore errors"; verdict=1; }
[ "${tables:-0}" -lt 10 ] && { echo "FAIL: only ${tables:-0} tables restored"; verdict=1; }
[ "${ohlcv:-0}" -lt 1 ] && { echo "FAIL: ohlcv came back empty"; verdict=1; }

echo
if [ "$verdict" -eq 0 ]; then
  echo "[$(date -Is)] DRILL PASSED — $(basename "$DUMP") restored into a live"
  echo "Postgres and came back with $tables tables / $ohlcv ohlcv rows."
else
  echo "[$(date -Is)] DRILL FAILED — see above. The backup did NOT restore cleanly."
fi
exit "$verdict"
