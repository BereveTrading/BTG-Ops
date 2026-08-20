#!/usr/bin/env bash
# BTG Stage 4 — PostgreSQL 16 + TimescaleDB install (NO DATA INGEST)
# Run as root:   sudo bash ~/btg/ops/stage4-install.sh
# Idempotent + halts on first error. Stops BEFORE any data ingest by design.
set -euo pipefail

DEV=/dev/nvme0n1p2
PREUUID=0361b96c-090e-49e1-b9db-2dbd69366b5e # inspected-empty UUID; guards the format target
MP=/var/lib/postgresql
PG=16
DB=btg

say(){ printf '\n=== %s ===\n' "$*"; }
die(){ printf '\n!!! HALT: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root:  sudo bash $0"

say "STEP 1/6 — reformat & mount the dedicated DB drive at $MP"
# --- destructive step: explicitly authorized by Dean. Guards so we can ONLY
#     touch the exact partition already inspected-empty (UUID $PREUUID). ---
[ "$DEV" = "/dev/nvme0n1p2" ] || die "unexpected device path $DEV"
blkid -o value -s UUID "$DEV" | grep -qx "$PREUUID" \
  || die "UUID of $DEV != inspected-empty UUID $PREUUID — refusing to format (wrong/renumbered device?)"
findmnt -S "$DEV" >/dev/null 2>&1 && die "$DEV is currently mounted somewhere — refusing to format"
findmnt / -no SOURCE | grep -qx "$DEV" && die "$DEV is the ROOT device — refusing to format"
echo ">>> Reformatting $DEV as ext4 (authorized). Prior content: empty boot/ cdrom/ leftovers."
mkfs.ext4 -F -L btg-tsdb "$DEV"
NEWUUID=$(blkid -o value -s UUID "$DEV"); echo "post-format UUID: $NEWUUID"
mkdir -p "$MP"
sed -i "\# $MP #d" /etc/fstab                      # drop any stale entry for this mountpoint
echo "UUID=$NEWUUID  $MP  ext4  defaults,noatime  0  2" >> /etc/fstab
mount "$MP"
mountpoint -q "$MP" || die "failed to mount $MP"
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS "$MP"

say "STEP 2/6 — add PGDG + official Timescale apt repositories"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl ca-certificates gnupg lsb-release >/dev/null
. /etc/os-release
install -d /usr/share/postgresql-common/pgdg
curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/timescaledb.list
apt-get update -qq

say "STEP 3/6 — install PostgreSQL $PG (fix data-dir ownership BEFORE the cluster is created)"
apt-get install -y postgresql-common
id postgres >/dev/null 2>&1 || die "postgres user was not created by postgresql-common"
chown postgres:postgres "$MP"; chmod 0755 "$MP"
apt-get install -y postgresql-$PG

say "STEP 4/6 — install TimescaleDB + tools, tune, restart"
apt-get install -y timescaledb-2-postgresql-$PG timescaledb-2-loader-postgresql-$PG timescaledb-tools
timescaledb-tune --quiet --yes \
  --pg-config="/usr/lib/postgresql/$PG/bin/pg_config" \
  --conf-path="/etc/postgresql/$PG/main/postgresql.conf" || die "timescaledb-tune failed"
systemctl restart "postgresql@$PG-main"
systemctl is-active --quiet "postgresql@$PG-main" || die "postgresql@$PG-main not active after restart"

say "STEP 5/6 — create database '$DB' and enable timescaledb extension"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
  || sudo -u postgres createdb "$DB"
sudo -u postgres psql -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

say "STEP 6/6 — verification (NO data ingested — this is the pre-ingest stop point)"
echo "-- clusters:";        pg_lsclusters
echo "-- data_directory:";  sudo -u postgres psql -tAc "SHOW data_directory;"
echo "-- backing mount:";   findmnt -no SOURCE,TARGET "$MP"
echo "-- server_version:";  sudo -u postgres psql -tAc "SHOW server_version;"
echo "-- timescaledb:";     sudo -u postgres psql -d "$DB" -tAc "SELECT extname||' '||extversion FROM pg_extension WHERE extname='timescaledb';"
echo "-- preload libs:";    sudo -u postgres psql -tAc "SHOW shared_preload_libraries;"
printf '\n>>> STAGE 4 INSTALL COMPLETE. No data ingested. Retention/CAGG gate is next. <<<\n'
