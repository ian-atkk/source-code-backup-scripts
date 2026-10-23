#!/bin/bash

set -u

. "$(dirname -- "$(realpath -- "$0")")/load-env.sh"

require_env FORGEJO_SERVICE FORGEJO_CONTAINER FORGEJO_UID LOG_DIR

FORGEJO_DIR="${1:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"
DESTINATION_DIR="${2:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"
STATE_FILE="${3:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"

FORGEJO_LOG="$LOG_DIR/forgejo_output.log"

# Set to 1 only while this script has Forgejo stopped.
FORGEJO_STOPPED_BY_US=0

if ! mkdir -p "$(dirname "$FORGEJO_LOG")"; then
    echo "$(date) [ERROR] [FORGEJO_SYSTEM] Failed to create log directory"
    exit 1
fi

start_new_forgejo_log() {
    local bar

    bar=$(printf '#%.0s' {1..80})

    {
        printf '\n\n%s\n' "$bar"
        printf '##  FORGEJO RUN |  %-59s##\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '%s\n' "$bar"
    } >>"$FORGEJO_LOG"
}

forgejo_compose() {
    docker compose -f "$FORGEJO_DIR/compose.yaml" "$@"
}

forgejo_running() {
    [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$FORGEJO_CONTAINER" \
            2>/dev/null
    )" = "true" ]
}

check_dir() {
    if [ ! -d "$FORGEJO_DIR" ]; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Forgejo directory not found: $FORGEJO_DIR"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Forgejo directory found: $FORGEJO_DIR"
    fi

    if [ ! -f "$FORGEJO_DIR/compose.yaml" ]; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] compose.yaml not found in: $FORGEJO_DIR"
        return 1
    fi

    if [ ! -d "$DESTINATION_DIR" ]; then
        echo "$(date) [INFO] [FORGEJO_CHECK] Destination directory not found, creating: $DESTINATION_DIR"

        if ! mkdir -p "$DESTINATION_DIR"; then
            echo "$(date) [ERROR] [FORGEJO_CHECK] Failed to create destination: $DESTINATION_DIR"
            return 1
        fi
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Destination directory found: $DESTINATION_DIR"
    fi

    if [ ! -w "$DESTINATION_DIR" ]; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Destination directory is not writable: $DESTINATION_DIR"
        return 1
    fi

    # Docker bind mounts need an absolute path.
    DESTINATION_DIR=$(realpath -e -- "$DESTINATION_DIR") || return 1

    return 0
}

check_forgejo_container() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Docker command not found"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Docker command found"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Docker Compose plugin is not available"
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] tar command not found"
        return 1
    fi

    if ! docker inspect "$FORGEJO_CONTAINER" >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Forgejo container not found: $FORGEJO_CONTAINER"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Forgejo container found: $FORGEJO_CONTAINER"
    fi

    if forgejo_running; then
        echo "$(date) [INFO] [FORGEJO_CHECK] Forgejo container running: $FORGEJO_CONTAINER"
    else
        echo "$(date) [WARNING] [FORGEJO_CHECK] Forgejo container is not running; it will be left stopped after the dump"
    fi

    return 0
}

stop_forgejo() {
    if ! forgejo_running; then
        return 0
    fi

    echo "$(date) [INFO] [FORGEJO_STOP] Stopping Forgejo for a consistent dump"
    echo -e "\n--- STOP ---" >>"$FORGEJO_LOG"

    # Set before stopping so the exit trap restarts Forgejo even if
    # the stop command fails halfway.
    FORGEJO_STOPPED_BY_US=1

    if ! forgejo_compose stop "$FORGEJO_SERVICE" >>"$FORGEJO_LOG" 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_STOP] Failed to stop Forgejo"
        return 1
    fi

    if forgejo_running; then
        echo "$(date) [ERROR] [FORGEJO_STOP] Forgejo is still running after stop"
        return 1
    fi

    echo "$(date) [INFO] [FORGEJO_STOP] Forgejo stopped"
    return 0
}

start_forgejo() {
    if [ "$FORGEJO_STOPPED_BY_US" -ne 1 ]; then
        return 0
    fi

    echo "$(date) [INFO] [FORGEJO_START] Starting Forgejo"
    echo -e "\n--- START ---" >>"$FORGEJO_LOG"

    if ! forgejo_compose start "$FORGEJO_SERVICE" >>"$FORGEJO_LOG" 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_START] Failed to start Forgejo; the service is DOWN"
        return 1
    fi

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if forgejo_running; then
            FORGEJO_STOPPED_BY_US=0
            echo "$(date) [INFO] [FORGEJO_START] Forgejo running again"
            return 0
        fi

        sleep 3
    done

    echo "$(date) [ERROR] [FORGEJO_START] Forgejo did not come back up; the service is DOWN"
    return 1
}

create_forgejo_dump() {
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    DUMP_NAME="forgejo-dump-${TIMESTAMP}.tar"
    HOST_DUMP="${DESTINATION_DIR}/${DUMP_NAME}"

    echo "$(date) [INFO] [FORGEJO_DUMP] Creating dump: $DUMP_NAME"
    echo -e "\n--- DUMP ---" >>"$FORGEJO_LOG"

    # Plain tar (not compressed): restic compresses and deduplicates it,
    # so only changed data is stored each night.
    #
    # The dump runs in a one-off container against the same /data volume
    # while the main container is stopped.
    if ! forgejo_compose run \
        --rm \
        --no-deps \
        -T \
        -u "$FORGEJO_UID" \
        -w /tmp \
        -v "$DESTINATION_DIR:/backup" \
        "$FORGEJO_SERVICE" \
        forgejo dump \
        --file "/backup/$DUMP_NAME" \
        --type tar \
        >>"$FORGEJO_LOG" 2>&1; then

        echo "$(date) [ERROR] [FORGEJO_DUMP] Forgejo dump creation failed"
        return 1
    fi

    if [ ! -s "$HOST_DUMP" ]; then
        echo "$(date) [ERROR] [FORGEJO_DUMP] Dump is missing or empty: $HOST_DUMP"
        return 1
    fi

    {
        ls -lh "$HOST_DUMP"
        sha256sum "$HOST_DUMP"
    } >>"$FORGEJO_LOG" 2>&1

    echo "$(date) [INFO] [FORGEJO_DUMP] Forgejo dump successfully created at: $HOST_DUMP"
    return 0
}

validate_dump() {
    local entries
    local repository_entries

    echo "$(date) [INFO] [FORGEJO_VALIDATE] Validating dump: $HOST_DUMP"
    echo -e "\n--- VALIDATE ---" >>"$FORGEJO_LOG"

    # Listing reads the whole archive, so truncation is detected here.
    if entries=$(tar -tf "$HOST_DUMP" 2>>"$FORGEJO_LOG"); then
        echo "TAR integrity: OK" >>"$FORGEJO_LOG"
    else
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] TAR integrity check failed: $HOST_DUMP"
        return 1
    fi

    if ! grep -qx 'app.ini' <<<"$entries"; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] app.ini not found in dump"
        return 1
    fi

    echo "found: app.ini" >>"$FORGEJO_LOG"

    if ! grep -qx 'forgejo-db.sql' <<<"$entries"; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] forgejo-db.sql not found in dump"
        return 1
    fi

    echo "found: forgejo-db.sql" >>"$FORGEJO_LOG"

    repository_entries=$(
        grep -c '^repos/' <<<"$entries" || true
    )

    if [ "$repository_entries" -eq 0 ]; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] Repository data not found in dump"
        return 1
    fi

    echo "found: repos/ ($repository_entries entries)" >>"$FORGEJO_LOG"

    echo "$(date) [INFO] [FORGEJO_VALIDATE] Forgejo dump validation successful"
    return 0
}

write_state_file() {
    local temporary_state

    temporary_state="${STATE_FILE}.tmp"

    if ! printf '%s\n' "$HOST_DUMP" >"$temporary_state"; then
        echo "$(date) [ERROR] [FORGEJO_SYSTEM] Failed to write temporary state file"
        return 1
    fi

    if ! mv -- "$temporary_state" "$STATE_FILE"; then
        echo "$(date) [ERROR] [FORGEJO_SYSTEM] Failed to publish state file: $STATE_FILE"
        rm -f -- "$temporary_state"
        return 1
    fi

    echo "$(date) [INFO] [FORGEJO_SYSTEM] Dump path recorded in: $STATE_FILE"
    return 0
}

failure_cleanup() {
    # An incomplete or invalid dump must not end up in the next restic
    # snapshot; the log keeps the details.
    if [ -n "${HOST_DUMP:-}" ] && [ -f "$HOST_DUMP" ]; then
        rm -f -- "$HOST_DUMP"
        echo "$(date) [INFO] [FORGEJO_CLEANUP] Removed failed dump: $HOST_DUMP"
    fi

    rm -f -- "$STATE_FILE"
}

# Restart Forgejo however the script ends (error, Ctrl-C, kill).
trap 'start_forgejo' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main() {
    start_new_forgejo_log

    check_dir || return $?
    check_forgejo_container || return $?
    stop_forgejo || return $?
    create_forgejo_dump || return $?

    # Bring Forgejo back before validating to keep the downtime short.
    start_forgejo || return $?

    validate_dump || return $?
    write_state_file || return $?

    echo "$(date) [INFO] [FORGEJO_SYSTEM] Forgejo backup artifact ready: $HOST_DUMP"
    return 0
}

if main; then
    exit 0
else
    exit_code=$?

    echo "$(date) [ERROR] [FORGEJO_SYSTEM] Forgejo backup preparation failed (exit_code=$exit_code)"

    failure_cleanup

    exit "$exit_code"
fi
