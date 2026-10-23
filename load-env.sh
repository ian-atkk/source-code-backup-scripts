#!/bin/bash
#
# Sourced by the backup and restore scripts. Loads backup.env and
# exports its variables so child scripts inherit them.

ENV_FILE="${BACKUP_ENV_FILE:-$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/backup.env}"

if [ ! -r "$ENV_FILE" ]; then
    echo "$(date) [ERROR] [ENV] Env file not found or not readable: $ENV_FILE"
    echo "$(date) [ERROR] [ENV] Copy backup.env.example to backup.env and adjust it"
    exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

# Fail with a clear message when a script needs a variable the env file lacks.
require_env() {
    local name

    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            echo "$(date) [ERROR] [ENV] $name is not set in $ENV_FILE"
            exit 1
        fi
    done
}
