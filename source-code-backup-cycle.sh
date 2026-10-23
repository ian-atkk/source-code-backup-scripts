#!/bin/bash

set -u

SCRIPT_DIR=$(dirname -- "$(realpath -- "$0")")

. "$SCRIPT_DIR/load-env.sh"

require_env FORGEJO_DIR BACKUP_DIR STATE_FILE LOCK_FILE

# Only one cycle at a time: the dump step stops and starts Forgejo.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "$(date) [WARNING] [BACKUP_CYCLE] Backup cycle already running. Exiting."
    exit 1
fi

echo "$(date) [INFO] [BACKUP_CYCLE] Starting backup cycle"

# Remove state left by an earlier interrupted run.
rm -f -- "$STATE_FILE"

# Step 1: Create and validate the Forgejo dump.
"$SCRIPT_DIR/forgejo_backup.sh" \
    "$FORGEJO_DIR" \
    "$BACKUP_DIR" \
    "$STATE_FILE"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] Forgejo backup preparation failed (exit_code=$exit_code)"
    exit "$exit_code"
fi

# The Forgejo script must record the exact dump it created.
if [ ! -s "$STATE_FILE" ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] Dump state file is missing or empty"
    exit 1
fi

DUMP_FILE=$(<"$STATE_FILE")

# Confirm the recorded file exists before running Restic.
if [ ! -s "$DUMP_FILE" ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] Recorded Forgejo dump is missing or empty: $DUMP_FILE"
    rm -f -- "$STATE_FILE"
    exit 1
fi

echo "$(date) [INFO] [BACKUP_CYCLE] Forgejo artifact ready: $DUMP_FILE"

# Step 2: Protect the staging directory with Restic.
"$SCRIPT_DIR/restic_backup.sh" "$BACKUP_DIR"

exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] Restic backup failed; retaining dump: $DUMP_FILE"

    # Keep both the dump and state file for investigation.
    exit "$exit_code"
fi

# Step 3: Mirror the restic repository offsite.
"$SCRIPT_DIR/rclone_sync.sh"

sync_exit_code=$?

if [ "$sync_exit_code" -ne 0 ]; then
    # The local backup is already safe in restic, so cleanup can still run;
    # the failure is reported at the end of the cycle.
    echo "$(date) [ERROR] [BACKUP_CYCLE] Offsite sync failed (exit_code=$sync_exit_code)"
fi

# Step 4: Delete only the exact dump created during this cycle.
"$SCRIPT_DIR/cleanup-forgejo-dump.sh" \
    "$DUMP_FILE" \
    "$BACKUP_DIR"

cleanup_exit_code=$?

if [ "$cleanup_exit_code" -ne 0 ]; then
    # The backup itself succeeded. The dump remaining on disk is safer
    # than reporting the protected backup as failed.
    echo "$(date) [WARNING] [BACKUP_CYCLE] Restic succeeded, but staging cleanup failed"
fi

rm -f -- "$STATE_FILE"

if [ "$sync_exit_code" -ne 0 ]; then
    echo "$(date) [WARNING] [BACKUP_CYCLE] Backup cycle finished, but offsite copy is out of date"
    exit "$sync_exit_code"
fi

echo "$(date) [INFO] [BACKUP_CYCLE] Backup cycle completed successfully"
exit 0

