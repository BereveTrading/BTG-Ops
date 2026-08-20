#!/bin/bash
# Push the newest verified dump OFF THIS MACHINE (Backblaze B2 or S3, via rclone).
#
# STATUS ON THIS BOX AS OF 2026-07-24: NOT YET ACTIVE.
#   - rclone is NOT installed
#   - no credentials exist
# The script is written to fail SAFE and LOUD in that state: it explains exactly
# what is missing and exits 0, because "offsite not configured yet" is a known
# gap, not a nightly backup failure. Once configured, a real push failure exits
# non-zero so it shows up as a problem.
#
# ---------------------------------------------------------------------------
# WHAT DEAN NEEDS TO DO (one time)
#
# 1. Install rclone:
#        sudo -v ; curl https://rclone.org/install.sh | sudo bash
#    (or: sudo apt install rclone — older, but fine)
#
# 2. Create a bucket + application key. Either provider works:
#
#    BACKBLAZE B2 (cheapest for this size — ~13GB is a few cents a month)
#      - sign up at backblaze.com, Object Storage / B2
#      - create a PRIVATE bucket, e.g. "btg-db-offsite"
#      - App Keys -> "Add a New Application Key", scoped to that bucket,
#        with read+write. You get TWO strings:
#            keyID          (looks like 0035f8a1b2c3d4e0000000001)
#            applicationKey (looks like K003xxxxxxxxxxxxxxxxxxxxxxxxxxx)
#        The applicationKey is shown ONCE. Copy it immediately.
#
#    AWS S3
#      - create a private bucket
#      - an IAM user with s3:PutObject/GetObject/ListBucket/DeleteObject on it
#      - you get an Access Key ID + Secret Access Key
#
# 3. Configure the rclone remote (interactive, ~1 minute):
#        rclone config
#      name it exactly:  btg-offsite
#      type: b2   (or s3)
#      paste keyID / applicationKey when asked
#
# 4. Create the config file this script reads:
#        cp /home/dean/btg/ops/db-backup/offsite.env.example \
#           /home/dean/btg/ops/db-backup/offsite.env
#        chmod 600 /home/dean/btg/ops/db-backup/offsite.env
#      then edit it and set BTG_OFFSITE_REMOTE to your bucket, e.g.
#        BTG_OFFSITE_REMOTE=btg-offsite:btg-db-offsite
#
# 5. Set an encryption passphrase (see offsite.env.example). The dumps contain
#    the full market DB and the globals file contains role password hashes —
#    neither should sit in a bucket in the clear.
#    *** STORE THE PASSPHRASE IN A PASSWORD MANAGER. WITHOUT IT THE OFFSITE
#        COPIES ARE UNRECOVERABLE. ***
#
# 6. Test:  /home/dean/btg/ops/db-backup/offsite-push.sh
#    After that the nightly job calls it automatically.
# ---------------------------------------------------------------------------
set -uo pipefail

BACKUP_DIR=/home/dean/btg/db-backups
CONF=/home/dean/btg/ops/db-backup/offsite.env
KEEP_REMOTE=30
TAG="[offsite]"

say() { echo "$TAG $(date -Is) $*"; }

# --- gate 1: rclone present? ------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
  say "SKIPPED — rclone is not installed. Offsite backup is NOT running."
  say "         fix: curl https://rclone.org/install.sh | sudo bash"
  exit 0
fi

# --- gate 2: config present? ------------------------------------------------
if [ ! -f "$CONF" ]; then
  say "SKIPPED — $CONF does not exist. Offsite backup is NOT running."
  say "         fix: copy offsite.env.example to offsite.env and fill it in."
  exit 0
fi

# shellcheck disable=SC1090
set -a; . "$CONF"; set +a

BTG_OFFSITE_REMOTE=${BTG_OFFSITE_REMOTE:-}
BTG_OFFSITE_ENCRYPT=${BTG_OFFSITE_ENCRYPT:-1}
BTG_OFFSITE_PASSFILE=${BTG_OFFSITE_PASSFILE:-/home/dean/btg/ops/db-backup/offsite.passphrase}

if [ -z "$BTG_OFFSITE_REMOTE" ]; then
  say "SKIPPED — BTG_OFFSITE_REMOTE is empty in $CONF. Offsite backup is NOT running."
  exit 0
fi

# --- gate 3: remote actually reachable? (real failure from here on) ---------
if ! rclone lsd "$BTG_OFFSITE_REMOTE" >/dev/null 2>&1; then
  say "ERROR — remote '$BTG_OFFSITE_REMOTE' is not reachable."
  say "        check 'rclone config' and that the bucket exists."
  exit 1
fi

# --- pick the newest verified dump -----------------------------------------
DUMP=$(ls -1t "$BACKUP_DIR"/btg-*.dump 2>/dev/null | head -1)
GLOBALS=$(ls -1t "$BACKUP_DIR"/globals-*.sql 2>/dev/null | head -1)
if [ -z "${DUMP:-}" ]; then
  say "ERROR — no dump found in $BACKUP_DIR"
  exit 1
fi

# Never ship something we haven't read end-to-end.
if ! pg_restore -f /dev/null "$DUMP" 2>/dev/null; then
  say "ERROR — refusing to upload $(basename "$DUMP"): it does not read end-to-end."
  exit 1
fi

WORK=$(mktemp -d /tmp/btg-offsite.XXXXXX) || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

rc=0
for src in "$DUMP" "$GLOBALS"; do
  [ -n "$src" ] && [ -e "$src" ] || continue
  base=$(basename "$src")

  if [ "$BTG_OFFSITE_ENCRYPT" = "1" ]; then
    if [ ! -f "$BTG_OFFSITE_PASSFILE" ]; then
      say "ERROR — encryption is on but passphrase file $BTG_OFFSITE_PASSFILE is missing."
      say "        Refusing to upload the database in the clear."
      say "        fix: write a long passphrase into that file, chmod 600 it,"
      say "             and SAVE IT IN A PASSWORD MANAGER (no passphrase = no restore)."
      exit 1
    fi
    out="$WORK/$base.gpg"
    if ! gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
             --passphrase-file "$BTG_OFFSITE_PASSFILE" \
             --output "$out" "$src"; then
      say "ERROR — encryption failed for $base"
      rc=1; continue
    fi
    upload="$out"; remote_name="$base.gpg"
  else
    say "WARNING — BTG_OFFSITE_ENCRYPT=0: uploading UNENCRYPTED. The globals file"
    say "          contains role password hashes. Strongly reconsider."
    upload="$src"; remote_name="$base"
  fi

  say "uploading $remote_name ($(du -h "$upload" | cut -f1)) -> $BTG_OFFSITE_REMOTE"
  if rclone copyto "$upload" "$BTG_OFFSITE_REMOTE/$remote_name" \
        --transfers 1 --retries 3 --low-level-retries 10 --stats-one-line; then
    # Prove it landed at the right size rather than trusting the exit code.
    lsize=$(stat -c%s "$upload")
    rsize=$(rclone lsjson "$BTG_OFFSITE_REMOTE/$remote_name" 2>/dev/null \
              | grep -o '"Size":[0-9]*' | head -1 | cut -d: -f2)
    if [ "${rsize:-0}" = "$lsize" ]; then
      say "ok $remote_name ($lsize bytes confirmed on remote)"
    else
      say "ERROR — size mismatch for $remote_name: local=$lsize remote=${rsize:-none}"
      rc=1
    fi
  else
    say "ERROR — upload failed for $remote_name"
    rc=1
  fi
done

# --- prune remote ----------------------------------------------------------
if [ "$rc" -eq 0 ]; then
  for pat in 'btg-' 'globals-'; do
    rclone lsf "$BTG_OFFSITE_REMOTE" 2>/dev/null | grep "^$pat" | sort -r \
      | tail -n +$((KEEP_REMOTE + 1)) | while read -r old; do
        say "pruning remote $old"
        rclone deletefile "$BTG_OFFSITE_REMOTE/$old" >/dev/null 2>&1 || true
      done
  done
  say "offsite push complete"
fi

exit "$rc"
