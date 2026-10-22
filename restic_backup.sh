#!/bin/bash

set -u

WORKING_DIR="${1:?Usage: $0 <working-directory>}"

export RESTIC_REPOSITORY="$HOME/forgejo-restic-repo"
export RESTIC_PASSWORD_FILE="$HOME/.forgejo-restic-pass"

RESTIC_LOG="$HOME/source-code-backup-logs/restic_output.log"
LOCK_FILE="/tmp/restic_backup.lock"

if ! mkdir -p "$(dirname "$RESTIC_LOG")"; then
    echo "$(date) [ERROR] [RESTIC_SYSTEM] Failed to create log directory"
    exit 1
fi

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "$(date) [WARNING] [RESTIC_SYSTEM] Backup already running. Exiting."
    exit 1
fi

if [ ! -d "$WORKING_DIR" ]; then
    echo "$(date) [ERROR] [RESTIC_SYSTEM] Working directory not found: $WORKING_DIR"
    exit 1
fi

if ! command -v restic >/dev/null 2>&1; then
    echo "$(date) [ERROR] [RESTIC_SYSTEM] restic is not installed."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "$(date) [ERROR] [RESTIC_SYSTEM] jq is not installed."
    exit 1
fi

if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
    echo "$(date) [ERROR] [RESTIC_SYSTEM] Password file is not readable: $RESTIC_PASSWORD_FILE"
    exit 1
fi

start_new_restic_log() {
    local bar

    bar=$(printf '#%.0s' {1..80})

    {
        printf '\n\n%s\n' "$bar"
        printf '##  RESTIC RUN  |  %-59s##\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '%s\n' "$bar"
    } >>"$RESTIC_LOG"
}

script_exit_log() {
    local exit_code="$1"

    echo "$(date) [ERROR] [RESTIC_SYSTEM] Stopping script (exit_code=$exit_code)"
}

JQ_HB='def hb:
    if . >= 1073741824 then "\(./1073741824*100|round/100) GiB"
    elif . >= 1048576 then "\(./1048576*100|round/100) MiB"
    elif . >= 1024 then "\(./1024*100|round/100) KiB"
    else "\(.) B"
    end;'

backup_folder() {
    local err_file
    local backup_output
    local exit_code
    local backup_errors
    local summary
    local snapshot_id

    echo "$(date) [INFO] [RESTIC_BACKUP] Creating backup"
    echo -e "\n--- BACKUP ---" >>"$RESTIC_LOG"

    err_file=$(mktemp)

    backup_output=$(
        restic backup \
            "$WORKING_DIR" \
            --skip-if-unchanged \
            --json \
            2>"$err_file"
    )

    exit_code=$?
    backup_errors=$(<"$err_file")

    rm -f "$err_file"

    summary=$(
        jq -c \
            'select(.message_type == "summary")' \
            <<<"$backup_output" \
            2>/dev/null
    )

    if [ -n "$summary" ]; then
        jq -r "$JQ_HB"'
            "snapshot:  \(.snapshot_id[0:8] // "none (unchanged, skipped)")",
            "files:     \(.files_new) new, \(.files_changed) changed, \(.files_unmodified) unmodified",
            "dirs:      \(.dirs_new) new, \(.dirs_changed) changed, \(.dirs_unmodified) unmodified",
            "added:     \(.data_added|hb) (\(.data_added_packed|hb) stored)",
            "processed: \(.total_files_processed) files, \(.total_bytes_processed|hb)",
            "duration:  \(.total_duration*100|round/100)s"
        ' <<<"$summary" >>"$RESTIC_LOG"

        echo "raw: $summary" >>"$RESTIC_LOG"
    fi

    if [ -n "$backup_errors" ]; then
        {
            echo "errors:"
            echo "$backup_errors"
        } >>"$RESTIC_LOG"
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$(date) [ERROR] [RESTIC_BACKUP] Backup failed (exit_code=$exit_code)"
        return "$exit_code"
    fi

    snapshot_id=$(
        jq -r '.snapshot_id // empty' <<<"$summary"
    )

    if [ -z "$snapshot_id" ]; then
        echo "$(date) [INFO] [RESTIC_BACKUP] No changes detected; snapshot skipped"
    else
        echo "$(date) [INFO] [RESTIC_BACKUP] Snapshot id: ${snapshot_id:0:8} successfully created"
    fi

    return 0
}

list_snapshots() {
    local exit_code

    echo "$(date) [INFO] [RESTIC_SNAPSHOTS] Getting snapshot list"
    echo -e "\n--- SNAPSHOTS ---" >>"$RESTIC_LOG"

    restic snapshots >>"$RESTIC_LOG" 2>&1
    exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "$(date) [INFO] [RESTIC_SNAPSHOTS] Snapshot list successfully retrieved"
        return 0
    else
        echo "$(date) [ERROR] [RESTIC_SNAPSHOTS] Failed to retrieve snapshot list (exit_code=$exit_code)"
        return "$exit_code"
    fi
}

check_repo_integrity() {
    local exit_code

    echo "$(date) [INFO] [RESTIC_CHECK] Starting repository integrity check"
    echo -e "\n--- CHECK ---" >>"$RESTIC_LOG"

    restic check >>"$RESTIC_LOG" 2>&1
    exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "$(date) [INFO] [RESTIC_CHECK] Repository integrity check complete"
        return 0
    else
        echo "$(date) [ERROR] [RESTIC_CHECK] Repository integrity check failed (exit_code=$exit_code)"
        return "$exit_code"
    fi
}

check_repo_integrity_subset() {
    local subset="$1"
    local exit_code

    echo "$(date) [INFO] [RESTIC_CHECK] Starting repository data check for subset $subset"
    echo -e "\n--- DATA CHECK: $subset ---" >>"$RESTIC_LOG"

    restic check \
        --read-data-subset="$subset" \
        >>"$RESTIC_LOG" 2>&1

    exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "$(date) [INFO] [RESTIC_CHECK] Repository subset $subset checked successfully"
        return 0
    else
        echo "$(date) [ERROR] [RESTIC_CHECK] Repository subset check failed (exit_code=$exit_code)"
        return "$exit_code"
    fi
}

check_repo_integrity_full() {
    local exit_code

    echo "$(date) [INFO] [RESTIC_CHECK] Starting full repository integrity check"
    echo -e "\n--- FULL CHECK ---" >>"$RESTIC_LOG"

    restic check --read-data >>"$RESTIC_LOG" 2>&1
    exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "$(date) [INFO] [RESTIC_CHECK] Full repository integrity check complete"
        return 0
    else
        echo "$(date) [ERROR] [RESTIC_CHECK] Full repository integrity check failed (exit_code=$exit_code)"
        return "$exit_code"
    fi
}

cleanup_snapshots() {
    local err_file
    local forget_output
    local exit_code
    local forget_errors
    local kept_count
    local removed_count
    local removed_ids

    echo "$(date) [INFO] [RESTIC_CLEANUP] Cleaning up snapshots"
    echo -e "\n--- CLEANUP ---" >>"$RESTIC_LOG"

    err_file=$(mktemp)

    forget_output=$(
        restic forget \
            --path "$WORKING_DIR" \
            --host "$(hostname)" \
            --keep-daily 7 \
            --keep-weekly 46 \
            --json \
            2>"$err_file"
    )

    exit_code=$?
    forget_errors=$(<"$err_file")

    rm -f "$err_file"

    if [ "$exit_code" -ne 0 ]; then
        {
            echo "$forget_output"
            echo "$forget_errors"
        } >>"$RESTIC_LOG"

        echo "$(date) [ERROR] [RESTIC_CLEANUP] Cleanup failed (exit_code=$exit_code)"
        return "$exit_code"
    fi

    jq -r '
        .[] |
        "policy: keep-daily 7, keep-weekly 46 | host=\(.host) paths=\(.paths|join(","))",
        "kept \(.keep|length), removed \(.remove // [] | length)",
        (
            .remove // [] |
            .[] |
            "  removed \(.short_id)  \(.time[0:19] | sub("T"; " "))"
        )
    ' <<<"$forget_output" >>"$RESTIC_LOG"

    if [ -n "$forget_errors" ]; then
        {
            echo "errors:"
            echo "$forget_errors"
        } >>"$RESTIC_LOG"
    fi

    kept_count=$(
        jq '[.[].keep[]?] | length' <<<"$forget_output"
    )

    removed_count=$(
        jq '[.[].remove[]?] | length' <<<"$forget_output"
    )

    removed_ids=$(
        jq -r \
            '[.[].remove[]?.short_id] | join(", ")' \
            <<<"$forget_output"
    )

    echo "$(date) [INFO] [RESTIC_CLEANUP] Snapshot cleanup complete"
    echo "$(date) [INFO] [RESTIC_CLEANUP] Kept $kept_count snapshots; removed $removed_count"

    if [ "$removed_count" -gt 0 ]; then
        echo "$(date) [INFO] [RESTIC_CLEANUP] Removed snapshot IDs: $removed_ids"
    else
        echo "$(date) [INFO] [RESTIC_CLEANUP] No snapshots needed removal"
    fi

    return 0
}

prune_repository() {
    local prune_output
    local exit_code

    echo "$(date) [INFO] [RESTIC_PRUNE] Starting repository prune"
    echo -e "\n--- PRUNE ---" >>"$RESTIC_LOG"

    prune_output=$(restic prune 2>&1)
    exit_code=$?

    grep -v \
        '^\[[0-9]*:[0-9]*\]' \
        <<<"$prune_output" \
        >>"$RESTIC_LOG"

    if [ "$exit_code" -eq 0 ]; then
        echo "$(date) [INFO] [RESTIC_PRUNE] Repository prune complete"
        return 0
    else
        echo "$(date) [ERROR] [RESTIC_PRUNE] Repository prune failed (exit_code=$exit_code)"
        return "$exit_code"
    fi
}

main() {
    local exit_code

    start_new_restic_log

    backup_folder || {
        exit_code=$?
        script_exit_log "$exit_code"
        return "$exit_code"
    }

    cleanup_snapshots || {
        exit_code=$?
        script_exit_log "$exit_code"
        return "$exit_code"
    }

    prune_repository || {
        exit_code=$?
        script_exit_log "$exit_code"
        return "$exit_code"
    }

    check_repo_integrity_full || {
        exit_code=$?
        script_exit_log "$exit_code"
        return "$exit_code"
    }

    list_snapshots || {
        exit_code=$?
        script_exit_log "$exit_code"
        return "$exit_code"
    }

    return 0
}

if main; then
    notify-send \
        "Restic Backup" \
        "Backup cycle completed successfully" \
        >/dev/null 2>&1 || true

    exit 0
else
    exit_code=$?

    notify-send \
        "Restic Backup Failed" \
        "Backup cycle failed with exit code $exit_code" \
        >/dev/null 2>&1 || true

    exit "$exit_code"
fi
