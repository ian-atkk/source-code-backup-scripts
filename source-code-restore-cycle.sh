#!/bin/bash

set -u

SNAPSHOT_ID="${1:?Usage: $0 <snapshot-id>}"

SCRIPT_DIR="$HOME/source-code-backup-scripts"

RESTORE_DIR="$HOME/forgejo-restic-restore1"
RECOVERY_DIR="$HOME/forgejo-recovery"

RECOVERY_CONTAINER="forgejo-recovery"


echo "$(date) [INFO] [RESTORE_CYCLE] Starting restore cycle"
echo "$(date) [INFO] [RESTORE_CYCLE] Snapshot: $SNAPSHOT_ID"


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


if docker inspect "$RECOVERY_CONTAINER" >/dev/null 2>&1; then
    echo "$(date) [ERROR] [RESTORE_CYCLE] Recovery container already exists: $RECOVERY_CONTAINER"
    echo "$(date) [ERROR] [RESTORE_CYCLE] Remove the old recovery container before retrying"
    exit 1
fi


# Step 1: Restore the Forgejo ZIP from Restic.
"$SCRIPT_DIR/restic_restore.sh" \
    "$SNAPSHOT_ID" \
    "$RESTORE_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [RESTORE_CYCLE] Restic restore failed (exit_code=$exit_code)"
    exit "$exit_code"
fi


# Step 2: Find the restored Forgejo ZIP.
DUMP_FILE=$(
    find "$RESTORE_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'forgejo-dump-*.zip' \
        -print \
        -quit
)


if [ -z "$DUMP_FILE" ]; then
    echo "$(date) [ERROR] [RESTORE_CYCLE] Restored Forgejo dump was not found"
    exit 1
fi


if [ ! -s "$DUMP_FILE" ]; then
    echo "$(date) [ERROR] [RESTORE_CYCLE] Restored Forgejo dump is empty: $DUMP_FILE"
    exit 1
fi


echo "$(date) [INFO] [RESTORE_CYCLE] Restored artifact found: $DUMP_FILE"


# Step 3: Reconstruct and start the recovery Forgejo instance.
sudo -E "$SCRIPT_DIR/forgejo_restore.sh" \
    "$DUMP_FILE" \
    "$RECOVERY_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [RESTORE_CYCLE] Forgejo recovery failed (exit_code=$exit_code)"
    exit "$exit_code"
fi


echo "$(date) [INFO] [RESTORE_CYCLE] Restore cycle completed successfully"
echo
echo "Recovery instance:"
echo "  http://127.0.0.1:4001/"
echo
echo "Verify:"
echo "  - Login"
echo "  - Repositories"
echo "  - Commits / branches / tags"
echo "  - Issues / pull requests / comments"
echo "  - Changes after the selected snapshot are absent"
echo
echo "When finished:"
echo "  docker rm -f $RECOVERY_CONTAINER"
echo "  sudo rm -rf \"$RECOVERY_DIR\""
echo "  sudo rm -rf \"$RESTORE_DIR\""

exit 0