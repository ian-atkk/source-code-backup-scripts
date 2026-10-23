#!/bin/bash
# Syncs the restic repo to another location and verifies the copy.

set -u

. "$(dirname -- "$(realpath -- "$0")")/load-env.sh"

require_env RESTIC_REPOSITORY RCLONE_REMOTE LOG_DIR

RCLONE_LOG="$LOG_DIR/rclone_output.log"
LOCK_FILE="/tmp/restic_backup.lock"

if ! mkdir -p "$(dirname "$RCLONE_LOG")"; then
    echo "$(date) [ERROR] [RCLONE_SYNC] Failed to create log directory"
    exit 1
fi

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "$(date) [WARNING] [RCLONE_SYNC] Restic or sync already running. Exiting."
    exit 1
fi

start_new_rclone_log() {
    local bar

    bar=$(printf '#%.0s' {1..80})

    {
        printf '\n\n%s\n' "$bar"
        printf '##  RCLONE RUN  |  %-59s##\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '%s\n' "$bar"
    } >>"$RCLONE_LOG"
}

check_requirements() {
    if ! command -v rclone >/dev/null 2>&1; then
        echo "$(date) [ERROR] [RCLONE_SYNC] rclone is not installed"
        return 1
    fi

    if [ ! -d "$RESTIC_REPOSITORY" ]; then
        echo "$(date) [ERROR] [RCLONE_SYNC] Restic repository not found: $RESTIC_REPOSITORY"
        return 1
    fi

    if [ ! -f "$RESTIC_REPOSITORY/config" ] || [ ! -d "$RESTIC_REPOSITORY/data" ]; then
        echo "$(date) [ERROR] [RCLONE_SYNC] Not a restic repository: $RESTIC_REPOSITORY"
        return 1
    fi

    if ! rclone lsf "$RCLONE_REMOTE" --max-depth 1; then
        echo "$(date) [ERROR] [RCLONE_SYNC] Remote destination not found: $RCLONE_REMOTE"
        return 1
    fi

    return 0
}

sync_repository() {
    local exit_code

    echo "$(date) [INFO] [RCLONE_SYNC] Syncing $RESTIC_REPOSITORY to $RCLONE_REMOTE"
    echo -e "\n--- SYNC ---" >>"$RCLONE_LOG"

    rclone sync \
        "$RESTIC_REPOSITORY" \
        "$RCLONE_REMOTE" \
        --checksum \
        --log-file "$RCLONE_LOG" \
        --log-level INFO \
        --stats-one-line \
        --stats-log-level NOTICE

    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "$(date) [ERROR] [RCLONE_SYNC] Sync failed (exit_code=$exit_code)"
        return "$exit_code"
    fi

    echo "$(date) [INFO] [RCLONE_SYNC] Sync complete"
    return 0
}

verify_sync() {
    local exit_code
    local local_size
    local remote_size

    echo "$(date) [INFO] [RCLONE_VERIFY] Comparing $RESTIC_REPOSITORY with $RCLONE_REMOTE"
    echo -e "\n--- VERIFY ---" >>"$RCLONE_LOG"

    rclone check \
        "$RESTIC_REPOSITORY" \
        "$RCLONE_REMOTE" \
        --log-file "$RCLONE_LOG" \
        --log-level INFO

    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "$(date) [ERROR] [RCLONE_VERIFY] Destination does not match source (exit_code=$exit_code)"
        return "$exit_code"
    fi

    local_size=$(rclone size "$RESTIC_REPOSITORY" --json 2>>"$RCLONE_LOG")
    remote_size=$(rclone size "$RCLONE_REMOTE" --json 2>>"$RCLONE_LOG")

    {
        echo "local:  $(jq -r '"\(.count) files, \(.bytes) bytes"' <<<"$local_size")"
        echo "remote: $(jq -r '"\(.count) files, \(.bytes) bytes"' <<<"$remote_size")"
    } >>"$RCLONE_LOG"

    echo "$(date) [INFO] [RCLONE_VERIFY] Destination matches source"
    return 0
}

main() {
    start_new_rclone_log
    check_requirements || return $?
    sync_repository || return $?
    verify_sync || return $?
    return 0
}

if main; then
    exit 0
else
    exit_code=$?

    echo "$(date) [ERROR] [RCLONE_SYNC] Stopping script (exit_code=$exit_code)"
    exit "$exit_code"
fi
