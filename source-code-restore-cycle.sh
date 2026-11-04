#!/bin/bash
#
# Restores one restic snapshot of a source, verifies it with the source's
# verify.sh, then starts a test instance with its restore.sh (if it has one).

set -u

SCRIPT_DIR=$(dirname -- "$(realpath -- "$0")")

. "$SCRIPT_DIR/load-env.sh" || exit 1

SOURCE="${1:?Usage: $0 <source> <snapshot-id>}"
SNAPSHOT_ID="${2:?Usage: $0 <source> <snapshot-id>}"

SOURCE_DIR="$SCRIPT_DIR/sources/$SOURCE"

echo "$(date) [INFO] [RESTORE_CYCLE] Starting restore cycle"
echo "$(date) [INFO] [RESTORE_CYCLE] Source: $SOURCE"
echo "$(date) [INFO] [RESTORE_CYCLE] Snapshot: $SNAPSHOT_ID"

case "$SOURCE" in
"" | *[!a-z0-9_-]*)
  echo "$(date) [ERROR] [RESTORE_CYCLE] Invalid source name: '$SOURCE'"
  exit 1
  ;;
esac

if [ ! -x "$SOURCE_DIR/verify.sh" ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] Unknown source or verify.sh missing: $SOURCE_DIR"
  exit 1
fi

# Where to restore and recover can differ per source, so they may live
# in the source's source.env.
load_source_env "$SOURCE"

require_env RESTORE_DIR RECOVERY_DIR

# Prevent accidentally overwriting an existing restore.
if [ -e "$RESTORE_DIR" ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] Restore directory already exists: $RESTORE_DIR"
  echo "$(date) [ERROR] [RESTORE_CYCLE] Remove or rename it before starting a new recovery"
  exit 1
fi

# Prevent collision with an existing recovery environment.
if [ -e "$RECOVERY_DIR" ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] Recovery directory already exists: $RECOVERY_DIR"
  echo "$(date) [ERROR] [RESTORE_CYCLE] Remove or rename it before starting a new recovery"
  exit 1
fi

# Step 1: Restore the snapshot from restic.
"$SCRIPT_DIR/restic_restore.sh" \
  "$SNAPSHOT_ID" \
  "$RESTORE_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] Restic restore failed (exit_code=$exit_code)"
  exit "$exit_code"
fi

# Step 2: The source checks the restored backup.
"$SOURCE_DIR/verify.sh" "$RESTORE_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] Unable to verify restored backup (exit_code=$exit_code)"
  exit "$exit_code"
fi

echo "$(date) [INFO] [RESTORE_CYCLE] Restored backup verified: $RESTORE_DIR"

# Step 3: Start a test instance, if the source supports one.
if [ ! -e "$SOURCE_DIR/restore.sh" ]; then
  echo "$(date) [INFO] [RESTORE_CYCLE] $SOURCE has no restore.sh; the verified backup is in: $RESTORE_DIR"
  exit 0
fi

# sudo: restore.sh sets file ownership for the test instance.
# -E keeps the exported env variables.
sudo -E "$SOURCE_DIR/restore.sh" \
  "$RESTORE_DIR" \
  "$RECOVERY_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
  echo "$(date) [ERROR] [RESTORE_CYCLE] $SOURCE recovery failed (exit_code=$exit_code)"
  exit "$exit_code"
fi

echo "$(date) [INFO] [RESTORE_CYCLE] Restore cycle completed successfully"
echo
echo "When finished, stop the test instance (see above), then:"
echo "  sudo rm -rf \"$RECOVERY_DIR\""
echo "  sudo rm -rf \"$RESTORE_DIR\""

exit 0
