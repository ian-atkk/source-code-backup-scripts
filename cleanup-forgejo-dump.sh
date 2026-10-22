#!/bin/bash

set -u

DUMP_FILE="${1:?Usage: $0 <dump-file> <staging-directory>}"
STAGING_DIR="${2:?Usage: $0 <dump-file> <staging-directory>}"

cleanup_log() {
    local level="$1"

    shift

    echo "$(date) [$level] [FORGEJO_CLEANUP] $*"
}

cleanup_log INFO "Starting staging dump cleanup"

if [ ! -d "$STAGING_DIR" ]; then
    cleanup_log ERROR \
        "Staging directory does not exist: $STAGING_DIR"

    exit 1
fi

if [ ! -f "$DUMP_FILE" ] || [ -L "$DUMP_FILE" ]; then
    cleanup_log ERROR \
        "Dump is missing, is not a regular file, or is a symlink: $DUMP_FILE"

    exit 1
fi

RESOLVED_DUMP=$(
    realpath -e -- "$DUMP_FILE"
) || {
    cleanup_log ERROR \
        "Could not resolve dump path: $DUMP_FILE"

    exit 1
}

RESOLVED_STAGING=$(
    realpath -e -- "$STAGING_DIR"
) || {
    cleanup_log ERROR \
        "Could not resolve staging directory: $STAGING_DIR"

    exit 1
}

if [ "$(dirname -- "$RESOLVED_DUMP")" != "$RESOLVED_STAGING" ]; then
    cleanup_log ERROR \
        "Refusing to delete file outside staging directory: $RESOLVED_DUMP"

    exit 1
fi

case "$(basename -- "$RESOLVED_DUMP")" in
forgejo-dump-*.zip) ;;
*)
    cleanup_log ERROR \
        "Unexpected dump filename; refusing deletion: $RESOLVED_DUMP"

    exit 1
    ;;
esac

if [ ! -s "$RESOLVED_DUMP" ]; then
    cleanup_log ERROR \
        "Dump is empty; retaining it for investigation: $RESOLVED_DUMP"

    exit 1
fi

if rm -f -- "$RESOLVED_DUMP"; then
    cleanup_log INFO \
        "Successfully removed staging dump: $RESOLVED_DUMP"

    exit 0
else
    cleanup_log ERROR \
        "Failed to remove staging dump: $RESOLVED_DUMP"

    exit 1
fi
