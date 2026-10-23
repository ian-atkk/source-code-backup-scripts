#!/bin/bash

set -u

DUMP_FILE="${1:?Usage: $0 <forgejo-dump.zip> <recovery-directory>}"
RECOVERY_DIR="${2:?Usage: $0 <forgejo-dump.zip> <recovery-directory>}"

FORGEJO_IMAGE="${FORGEJO_IMAGE:-codeberg.org/forgejo/forgejo:15}"
FORGEJO_UID="${FORGEJO_UID:-1000}"
FORGEJO_GID="${FORGEJO_GID:-1000}"

RECOVERY_CONTAINER="forgejo-recovery"
RECOVERY_HOST="127.0.0.1"
RECOVERY_PORT="4001"
CONTAINER_PORT="3000"

EXTRACT_DIR="$RECOVERY_DIR/extracted"
RECOVERY_DATA="$RECOVERY_DIR/recovery-data"
COMPOSE_FILE="$RECOVERY_DIR/compose-recovery.yaml"

RESTORE_LOG="$HOME/source-code-backup-logs/forgejo_output.log"


restore_log()
{
    local level="$1"
    local component="$2"

    shift 2

    printf '%s [%s] [FORGEJO_RESTORE_%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$level" \
        "$component" \
        "$*" | tee -a "$RESTORE_LOG"
}


start_new_restore_log()
{
    local bar

    bar=$(printf '#%.0s' {1..80})

    {
        printf '\n\n%s\n' "$bar"
        printf '##  FORGEJO RESTORE  |  %-55s##\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '%s\n' "$bar"
    } >> "$RESTORE_LOG"
}


check_requirements()
{
    local command_name

    restore_log INFO CHECK "Checking restore requirements"

    for command_name in docker unzip sed find realpath; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            restore_log ERROR CHECK \
                "Required command not found: $command_name"
            return 1
        fi
    done

    if ! docker compose version >/dev/null 2>&1; then
        restore_log ERROR CHECK \
            "Docker Compose plugin is not available"
        return 1
    fi

    if [ ! -f "$DUMP_FILE" ]; then
        restore_log ERROR CHECK \
            "Forgejo dump does not exist: $DUMP_FILE"
        return 1
    fi

    if [ -L "$DUMP_FILE" ]; then
        restore_log ERROR CHECK \
            "Forgejo dump must not be a symbolic link: $DUMP_FILE"
        return 1
    fi

    if [ ! -s "$DUMP_FILE" ]; then
        restore_log ERROR CHECK \
            "Forgejo dump is empty: $DUMP_FILE"
        return 1
    fi

    if docker inspect "$RECOVERY_CONTAINER" >/dev/null 2>&1; then
        restore_log ERROR CHECK \
            "Recovery container already exists: $RECOVERY_CONTAINER"
        restore_log ERROR CHECK \
            "Stop and remove the existing recovery container before retrying"
        return 1
    fi

    restore_log INFO CHECK "Requirement checks passed"
    return 0
}


prepare_recovery_directory()
{
    restore_log INFO PREPARE \
        "Preparing recovery directory: $RECOVERY_DIR"

    if [ -e "$RECOVERY_DIR" ] && [ ! -d "$RECOVERY_DIR" ]; then
        restore_log ERROR PREPARE \
            "Recovery path exists but is not a directory: $RECOVERY_DIR"
        return 1
    fi

    if [ -d "$RECOVERY_DIR" ] &&
        [ -n "$(
            find "$RECOVERY_DIR" \
                -mindepth 1 \
                -maxdepth 1 \
                -print \
                -quit
        )" ]; then

        restore_log ERROR PREPARE \
            "Recovery directory is not empty: $RECOVERY_DIR"
        return 1
    fi

    if ! mkdir -p "$EXTRACT_DIR" "$RECOVERY_DATA"; then
        restore_log ERROR PREPARE \
            "Failed to create recovery directories"
        return 1
    fi

    restore_log INFO PREPARE "Recovery directory prepared"
    return 0
}


validate_dump()
{
    local repository_entries

    restore_log INFO VALIDATE \
        "Validating Forgejo dump: $DUMP_FILE"

    printf '\n--- DUMP VALIDATION ---\n' >> "$RESTORE_LOG"

    if ! unzip -t "$DUMP_FILE" >/dev/null 2>&1; then
        restore_log ERROR VALIDATE \
            "ZIP integrity validation failed"
        return 1
    fi

    echo "ZIP integrity: OK" >> "$RESTORE_LOG"

    if ! unzip -Z1 "$DUMP_FILE" | grep -qx 'app.ini'; then
        restore_log ERROR VALIDATE \
            "app.ini not found in Forgejo dump"
        return 1
    fi

    echo "found: app.ini" >> "$RESTORE_LOG"

    if ! unzip -Z1 "$DUMP_FILE" | grep -qx 'forgejo-db.sql'; then
        restore_log ERROR VALIDATE \
            "forgejo-db.sql not found in Forgejo dump"
        return 1
    fi

    echo "found: forgejo-db.sql" >> "$RESTORE_LOG"

    if ! unzip -Z1 "$DUMP_FILE" | grep -q '^data/'; then
        restore_log ERROR VALIDATE \
            "Forgejo application data not found in dump"
        return 1
    fi

    echo "found: data/" >> "$RESTORE_LOG"

    repository_entries=$(
        unzip -Z1 "$DUMP_FILE" |
            grep -c '^repos/' || true
    )

    if [ "$repository_entries" -eq 0 ]; then
        restore_log ERROR VALIDATE \
            "Forgejo repository data not found in dump"
        return 1
    fi

    echo "found: repos/ ($repository_entries entries)" \
        >> "$RESTORE_LOG"

    restore_log INFO VALIDATE \
        "Forgejo dump validation successful"

    return 0
}


extract_dump()
{
    restore_log INFO EXTRACT \
        "Extracting Forgejo dump into: $EXTRACT_DIR"

    printf '\n--- EXTRACT ---\n' >> "$RESTORE_LOG"

    if ! unzip -q "$DUMP_FILE" \
        -d "$EXTRACT_DIR" \
        >> "$RESTORE_LOG" 2>&1; then

        restore_log ERROR EXTRACT \
            "Failed to extract Forgejo dump"
        return 1
    fi

    if [ ! -f "$EXTRACT_DIR/app.ini" ]; then
        restore_log ERROR EXTRACT \
            "Extracted app.ini is missing"
        return 1
    fi

    if [ ! -d "$EXTRACT_DIR/data" ]; then
        restore_log ERROR EXTRACT \
            "Extracted data directory is missing"
        return 1
    fi

    if [ ! -d "$EXTRACT_DIR/repos" ]; then
        restore_log ERROR EXTRACT \
            "Extracted repositories directory is missing"
        return 1
    fi

    restore_log INFO EXTRACT \
        "Forgejo dump successfully extracted"

    return 0
}


prepare_forgejo_data()
{
    restore_log INFO DATA \
        "Reconstructing Forgejo data directory"

    printf '\n--- PREPARE DATA ---\n' >> "$RESTORE_LOG"

    if ! mkdir -p \
        "$RECOVERY_DATA/gitea/conf" \
        "$RECOVERY_DATA/git/repositories" \
        "$RECOVERY_DATA/git/.ssh"; then

        restore_log ERROR DATA \
            "Failed to create Forgejo data structure"
        return 1
    fi

    if ! cp -a \
        "$EXTRACT_DIR/data/." \
        "$RECOVERY_DATA/gitea/"; then

        restore_log ERROR DATA \
            "Failed to restore Forgejo application data"
        return 1
    fi

    if ! cp -a \
        "$EXTRACT_DIR/repos/." \
        "$RECOVERY_DATA/git/repositories/"; then

        restore_log ERROR DATA \
            "Failed to restore Forgejo repositories"
        return 1
    fi

    if ! cp \
        "$EXTRACT_DIR/app.ini" \
        "$RECOVERY_DATA/gitea/conf/app.ini"; then

        restore_log ERROR DATA \
            "Failed to restore app.ini"
        return 1
    fi

    if [ ! -s "$RECOVERY_DATA/gitea/gitea.db" ]; then
        restore_log ERROR DATA \
            "SQLite database file is missing or empty: gitea.db"
        return 1
    fi

    restore_log INFO DATA \
        "Forgejo application data restored"

    restore_log INFO DATA \
        "Forgejo repositories restored"

    restore_log INFO DATA \
        "SQLite database restored"

    return 0
}


configure_recovery_instance()
{
    local app_ini
    local recovery_url

    app_ini="$RECOVERY_DATA/gitea/conf/app.ini"
    recovery_url="http://${RECOVERY_HOST}:${RECOVERY_PORT}/"

    restore_log INFO CONFIG \
        "Configuring isolated recovery instance"

    printf '\n--- CONFIGURATION ---\n' >> "$RESTORE_LOG"

    if grep -qE '^[[:space:]]*ROOT_URL[[:space:]]*=' "$app_ini"; then
        if ! sed -i \
            "s|^[[:space:]]*ROOT_URL[[:space:]]*=.*|ROOT_URL = ${recovery_url}|" \
            "$app_ini"; then

            restore_log ERROR CONFIG \
                "Failed to update ROOT_URL"
            return 1
        fi
    else
        {
            printf '\n[server]\n'
            printf 'ROOT_URL = %s\n' "$recovery_url"
        } >> "$app_ini"
    fi

    restore_log INFO CONFIG \
        "Recovery ROOT_URL configured: $recovery_url"

    return 0
}


fix_permissions()
{
    restore_log INFO PERMISSIONS \
        "Setting Forgejo data ownership and permissions"

    printf '\n--- PERMISSIONS ---\n' >> "$RESTORE_LOG"

    if ! touch \
        "$RECOVERY_DATA/git/.ssh/authorized_keys"; then

        restore_log ERROR PERMISSIONS \
            "Failed to create authorized_keys"
        return 1
    fi

    if ! chown -R \
        "$FORGEJO_UID:$FORGEJO_GID" \
        "$RECOVERY_DATA"; then

        restore_log ERROR PERMISSIONS \
            "Failed to set recovery-data ownership"
        restore_log ERROR PERMISSIONS \
            "Run the restore script with sufficient chown permission"
        return 1
    fi

    if ! chmod 700 "$RECOVERY_DATA/git/.ssh"; then
        restore_log ERROR PERMISSIONS \
            "Failed to set .ssh directory permissions"
        return 1
    fi

    if ! chmod 600 \
        "$RECOVERY_DATA/git/.ssh/authorized_keys"; then

        restore_log ERROR PERMISSIONS \
            "Failed to set authorized_keys permissions"
        return 1
    fi

    restore_log INFO PERMISSIONS \
        "Forgejo ownership and permissions configured"

    return 0
}


create_recovery_compose()
{
    restore_log INFO COMPOSE \
        "Creating recovery Compose file: $COMPOSE_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  server:
    image: ${FORGEJO_IMAGE}
    container_name: ${RECOVERY_CONTAINER}
    restart: "no"

    environment:
      USER_UID: "${FORGEJO_UID}"
      USER_GID: "${FORGEJO_GID}"

    volumes:
      - ./recovery-data:/data
      - /etc/localtime:/etc/localtime:ro

    ports:
      - "${RECOVERY_HOST}:${RECOVERY_PORT}:${CONTAINER_PORT}"
EOF

    if ! docker compose \
        -f "$COMPOSE_FILE" \
        config \
        >> "$RESTORE_LOG" 2>&1; then

        restore_log ERROR COMPOSE \
            "Generated Compose configuration is invalid"
        return 1
    fi

    restore_log INFO COMPOSE \
        "Recovery Compose configuration created"

    return 0
}


start_recovery_instance()
{
    restore_log INFO START \
        "Starting isolated Forgejo recovery container"

    printf '\n--- CONTAINER START ---\n' >> "$RESTORE_LOG"

    if ! docker compose \
        -f "$COMPOSE_FILE" \
        up -d \
        >> "$RESTORE_LOG" 2>&1; then

        restore_log ERROR START \
            "Failed to start Forgejo recovery container"
        return 1
    fi

    sleep 5

    if [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$RECOVERY_CONTAINER" \
            2>/dev/null
    )" != "true" ]; then

        restore_log ERROR START \
            "Forgejo recovery container is not running"

        docker logs "$RECOVERY_CONTAINER" \
            --tail 100 \
            >> "$RESTORE_LOG" 2>&1 || true

        return 1
    fi

    restore_log INFO START \
        "Forgejo recovery container started"

    return 0
}


check_startup_logs()
{
    local startup_logs

    restore_log INFO CHECK \
        "Checking Forgejo recovery startup logs"

    printf '\n--- STARTUP LOGS ---\n' >> "$RESTORE_LOG"

    startup_logs=$(
        docker logs "$RECOVERY_CONTAINER" \
            --tail 200 \
            2>&1
    )

    printf '%s\n' "$startup_logs" >> "$RESTORE_LOG"

    if grep -qE \
        '\[F\]|permission denied|database.*failed|Init.*failed' \
        <<< "$startup_logs"; then

        restore_log ERROR CHECK \
            "Fatal error detected in Forgejo startup logs"
        return 1
    fi

    if ! grep -q \
        'ORM engine initialization successful' \
        <<< "$startup_logs"; then

        restore_log WARNING CHECK \
            "ORM initialization confirmation was not found yet"
        restore_log WARNING CHECK \
            "Review the complete container logs manually"
    else
        restore_log INFO CHECK \
            "Forgejo database initialization successful"
    fi

    return 0
}


show_verification_steps()
{
    printf '\n'
    restore_log INFO SYSTEM \
        "Forgejo recovery preparation completed"

    printf '\nManual verification required:\n'
    printf '  1. Open: http://%s:%s/\n' \
        "$RECOVERY_HOST" \
        "$RECOVERY_PORT"
    printf '  2. Log in with an account from the selected backup.\n'
    printf '  3. Confirm the expected repositories exist.\n'
    printf '  4. Confirm branches, tags and commits.\n'
    printf '  5. Confirm issues, pull requests and comments.\n'
    printf '  6. Confirm changes made after the snapshot are absent.\n'
    printf '\nContainer logs:\n'
    printf '  docker logs %s --tail 100\n' \
        "$RECOVERY_CONTAINER"
    printf '\nStop recovery instance:\n'
    printf '  docker compose -f %q down\n' \
        "$COMPOSE_FILE"
}


main()
{
    local exit_code

    start_new_restore_log

    check_requirements || {
        exit_code=$?
        return "$exit_code"
    }

    prepare_recovery_directory || {
        exit_code=$?
        return "$exit_code"
    }

    validate_dump || {
        exit_code=$?
        return "$exit_code"
    }

    extract_dump || {
        exit_code=$?
        return "$exit_code"
    }

    prepare_forgejo_data || {
        exit_code=$?
        return "$exit_code"
    }

    configure_recovery_instance || {
        exit_code=$?
        return "$exit_code"
    }

    fix_permissions || {
        exit_code=$?
        return "$exit_code"
    }

    create_recovery_compose || {
        exit_code=$?
        return "$exit_code"
    }

    start_recovery_instance || {
        exit_code=$?
        return "$exit_code"
    }

    check_startup_logs || {
        exit_code=$?
        return "$exit_code"
    }

    show_verification_steps
    return 0
}


if main; then
    exit 0
else
    exit_code=$?

    restore_log ERROR SYSTEM \
        "Forgejo recovery failed (exit_code=$exit_code)"

    if docker inspect "$RECOVERY_CONTAINER" \
        >/dev/null 2>&1; then

        restore_log WARNING SYSTEM \
            "Recovery container may require manual inspection"

        restore_log WARNING SYSTEM \
            "Check: docker logs $RECOVERY_CONTAINER --tail 100"
    fi

    exit "$exit_code"
fi