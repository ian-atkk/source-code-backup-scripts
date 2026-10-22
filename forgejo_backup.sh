#!/bin/bash

set -u

FORGEJO_DIR="${1:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"
DESTINATION_DIR="${2:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"
STATE_FILE="${3:?Usage: $0 <forgejo-directory> <destination-directory> <state-file>}"

FORGEJO_CONTAINER="forgejo"
FORGEJO_UID="1000"

FORGEJO_LOG="$HOME/source-code-backup-logs/forgejo_output.log"

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

    return 0
}

check_forgejo_container() {
    local running

    if ! command -v docker >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Docker command not found"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Docker command found"
    fi

    if ! docker inspect "$FORGEJO_CONTAINER" >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Forgejo container not found: $FORGEJO_CONTAINER"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Forgejo container found: $FORGEJO_CONTAINER"
    fi

    running=$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$FORGEJO_CONTAINER"
    )

    if [ "$running" != "true" ]; then
        echo "$(date) [ERROR] [FORGEJO_CHECK] Forgejo container not running: $FORGEJO_CONTAINER"
        return 1
    else
        echo "$(date) [INFO] [FORGEJO_CHECK] Forgejo container running: $FORGEJO_CONTAINER"
    fi

    return 0
}

create_forgejo_dump() {
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    DUMP_NAME="forgejo-dump-${TIMESTAMP}.zip"
    CONTAINER_DUMP="/tmp/${DUMP_NAME}"
    HOST_DUMP="${DESTINATION_DIR}/${DUMP_NAME}"

    echo "$(date) [INFO] [FORGEJO_DUMP] Creating dump: $DUMP_NAME"
    echo -e "\n--- DUMP ---" >>"$FORGEJO_LOG"

    if ! docker exec \
        -u "$FORGEJO_UID" \
        "$FORGEJO_CONTAINER" \
        forgejo dump \
        --file "$CONTAINER_DUMP" \
        --type zip \
        >>"$FORGEJO_LOG" 2>&1; then

        echo "$(date) [ERROR] [FORGEJO_DUMP] Forgejo dump creation failed"
        return 1
    fi

    if ! docker exec \
        "$FORGEJO_CONTAINER" \
        test -s "$CONTAINER_DUMP"; then

        echo "$(date) [ERROR] [FORGEJO_DUMP] Dump is missing or empty inside container: $CONTAINER_DUMP"
        return 1
    fi

    echo "$(date) [INFO] [FORGEJO_DUMP] Forgejo dump successfully created at: $CONTAINER_DUMP"
    return 0
}

copy_dump() {
    echo "$(date) [INFO] [FORGEJO_COPY] Copying dump to: $HOST_DUMP"
    echo -e "\n--- COPY ---" >>"$FORGEJO_LOG"

    if ! docker cp \
        "$FORGEJO_CONTAINER:$CONTAINER_DUMP" \
        "$HOST_DUMP" \
        >>"$FORGEJO_LOG" 2>&1; then

        echo "$(date) [ERROR] [FORGEJO_COPY] Forgejo copy failed"
        return 1
    fi

    if [ ! -s "$HOST_DUMP" ]; then
        echo "$(date) [ERROR] [FORGEJO_COPY] Dump copy is empty or missing: $HOST_DUMP"
        return 1
    fi

    {
        ls -lh "$HOST_DUMP"
        sha256sum "$HOST_DUMP"
    } >>"$FORGEJO_LOG" 2>&1

    echo "$(date) [INFO] [FORGEJO_COPY] Forgejo copied successfully to: $HOST_DUMP"
    return 0
}

validate_dump() {
    local repository_entries

    echo "$(date) [INFO] [FORGEJO_VALIDATE] Validating dump: $HOST_DUMP"
    echo -e "\n--- VALIDATE ---" >>"$FORGEJO_LOG"

    if ! command -v unzip >/dev/null 2>&1; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] unzip command not found"
        return 1
    fi

    if unzip -t "$HOST_DUMP" >/dev/null 2>&1; then
        echo "ZIP integrity: OK" >>"$FORGEJO_LOG"
    else
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] ZIP integrity check failed: $HOST_DUMP"
        return 1
    fi

    if ! unzip -Z1 "$HOST_DUMP" | grep -qx 'app.ini'; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] app.ini not found in dump"
        return 1
    fi

    echo "found: app.ini" >>"$FORGEJO_LOG"

    if ! unzip -Z1 "$HOST_DUMP" | grep -qx 'forgejo-db.sql'; then
        echo "$(date) [ERROR] [FORGEJO_VALIDATE] forgejo-db.sql not found in dump"
        return 1
    fi

    echo "found: forgejo-db.sql" >>"$FORGEJO_LOG"

    repository_entries=$(
        unzip -Z1 "$HOST_DUMP" |
            grep -c '^repos/' || true
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

remove_container_dump() {
    echo -e "\n--- CLEANUP ---" >>"$FORGEJO_LOG"

    if docker exec \
        "$FORGEJO_CONTAINER" \
        rm -v -f "$CONTAINER_DUMP" \
        >>"$FORGEJO_LOG" 2>&1; then

        echo "$(date) [INFO] [FORGEJO_CLEANUP] Temporary container dump removed: $CONTAINER_DUMP" \
            >>"$FORGEJO_LOG"
    else
        echo "$(date) [WARNING] [FORGEJO_CLEANUP] Failed to remove temporary container dump: $CONTAINER_DUMP" \
            >>"$FORGEJO_LOG"
    fi

    return 0
}

failure_cleanup() {
    if [ -n "${CONTAINER_DUMP:-}" ]; then
        docker exec \
            "$FORGEJO_CONTAINER" \
            rm -f "$CONTAINER_DUMP" \
            >/dev/null 2>&1 || true
    fi

    rm -f -- "$STATE_FILE"
}

main() {
    start_new_forgejo_log

    check_dir || return $?
    check_forgejo_container || return $?
    create_forgejo_dump || return $?
    copy_dump || return $?
    validate_dump || return $?
    write_state_file || return $?

    remove_container_dump

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
