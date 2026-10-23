#!/bin/bash

# Restores one restic snapshot into an empty directory and checks that it holds a single readable Forgejo dump tar.

set -u

. "$(dirname -- "$(realpath -- "$0")")/load-env.sh"

require_env RESTIC_REPOSITORY RESTIC_PASSWORD_FILE LOG_DIR BACKUP_DIR

SNAPSHOT_ID="${1:?Usage: $0 <snapshot-id> <target-directory>}"
RESTORE_DIR="${2:?Usage: $0 <snapshot-id> <target-directory>}"

RESTIC_LOG="$LOG_DIR/restic_output.log"

SNAPSHOT_PATH="$BACKUP_DIR"


if ! mkdir -p "$(dirname "$RESTIC_LOG")"; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] Failed to create log directory"
    exit 1
fi


check_requirements()
{
    if ! command -v restic >/dev/null 2>&1; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] restic is not installed"
        return 1
    fi

    if [ ! -d "$RESTIC_REPOSITORY" ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restic repository does not exist: $RESTIC_REPOSITORY"
        return 1
    fi

    if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Password file is not readable: $RESTIC_PASSWORD_FILE"
        return 1
    fi

    return 0
}


prepare_restore_directory()
{
    if [ -e "$RESTORE_DIR" ] && [ ! -d "$RESTORE_DIR" ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restore target exists but is not a directory: $RESTORE_DIR"
        return 1
    fi

    if [ -d "$RESTORE_DIR" ] &&
        [ -n "$(find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then

        echo "$(date) [ERROR] [RESTIC_RESTORE] Restore directory is not empty: $RESTORE_DIR"
        return 1
    fi

    if ! mkdir -p "$RESTORE_DIR"; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Failed to create restore directory: $RESTORE_DIR"
        return 1
    fi

    return 0
}


validate_snapshot()
{
    if ! restic snapshots "$SNAPSHOT_ID" >/dev/null 2>&1; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Snapshot not found: $SNAPSHOT_ID"
        return 1
    fi

    echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot found: $SNAPSHOT_ID"
    return 0
}


restore_snapshot()
{
    local exit_code

    echo "$(date) [INFO] [RESTIC_RESTORE] Restoring snapshot: $SNAPSHOT_ID"
    echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot path: $SNAPSHOT_PATH"
    echo "$(date) [INFO] [RESTIC_RESTORE] Restore target: $RESTORE_DIR"

    {
        printf '\n--- RESTORE ---\n'
        printf 'snapshot: %s\n' "$SNAPSHOT_ID"
        printf 'snapshot path: %s\n' "$SNAPSHOT_PATH"
        printf 'restore target: %s\n' "$RESTORE_DIR"
    } >> "$RESTIC_LOG"

    restic restore \
        "${SNAPSHOT_ID}:${SNAPSHOT_PATH}" \
        --target "$RESTORE_DIR" \
        >> "$RESTIC_LOG" 2>&1

    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Snapshot restore failed (exit_code=$exit_code)"
        return "$exit_code"
    fi

    echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot successfully restored to: $RESTORE_DIR"
    return 0
}


validate_restored_dump()
{
    local dump_count
    local restored_dump

    dump_count=$(
        find "$RESTORE_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'forgejo-dump-*.tar' |
            wc -l
    )

    if [ "$dump_count" -eq 0 ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] No Forgejo dump found in restore directory"
        return 1
    fi

    if [ "$dump_count" -gt 1 ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Multiple Forgejo dumps found in restore directory"
        return 1
    fi

    restored_dump=$(
        find "$RESTORE_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'forgejo-dump-*.tar' \
            -print \
            -quit
    )

    if [ ! -s "$restored_dump" ]; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restored dump is empty: $restored_dump"
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] tar is not installed"
        return 1
    fi

    if ! tar -tf "$restored_dump" >/dev/null 2>&1; then
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restored TAR failed integrity validation: $restored_dump"
        return 1
    fi

    echo "$(date) [INFO] [RESTIC_RESTORE] Restored TAR integrity: OK"
    echo "$(date) [INFO] [RESTIC_RESTORE] Restored artifact: $restored_dump"

    {
        echo "TAR integrity: OK"
        echo "restored artifact: $restored_dump"
        sha256sum "$restored_dump"
    } >> "$RESTIC_LOG"

    return 0
}


main()
{
    local exit_code

    check_requirements || {
        exit_code=$?
        echo "$(date) [ERROR] [RESTIC_RESTORE] Requirement checks failed"
        return "$exit_code"
    }

    prepare_restore_directory || {
        exit_code=$?
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restore-directory preparation failed"
        return "$exit_code"
    }

    validate_snapshot || {
        exit_code=$?
        echo "$(date) [ERROR] [RESTIC_RESTORE] Snapshot validation failed"
        return "$exit_code"
    }

    restore_snapshot || {
        exit_code=$?
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restore operation failed"
        return "$exit_code"
    }

    validate_restored_dump || {
        exit_code=$?
        echo "$(date) [ERROR] [RESTIC_RESTORE] Restored artifact validation failed"
        return "$exit_code"
    }

    echo "$(date) [INFO] [RESTIC_RESTORE] Restic restore cycle completed successfully"
    return 0
}


if main; then
    exit 0
else
    exit_code=$?

    echo "$(date) [ERROR] [RESTIC_RESTORE] Restore cycle stopped (exit_code=$exit_code)"
    exit "$exit_code"
fi