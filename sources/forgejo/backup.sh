#!/bin/bash
#
# Creates a live Forgejo dump (tar) in <staging-dir> for restic.
#
# Forgejo keeps running during the dump. This script runs as the
# forgejo-backup user, which cannot use Docker directly. The dump itself
# is made by a root-owned helper that forgejo-backup may run via sudo:
#   /usr/local/bin/forgejo-dump            (writes the tar to stdout)
#   /etc/sudoers.d/forgejo-dump            (allows only that one command)

set -u
umask 077 # every file this script creates is private (600)

. "$(dirname -- "$(realpath -- "$0")")/../../load-env.sh" || exit 1
load_source_env forgejo
require_env LOG_DIR

DESTINATION_DIR="${1:?Usage: $0 <staging-dir>}"

FORGEJO_LOG="$LOG_DIR/forgejo_output.log"

# Root-owned helper that runs `forgejo dump` inside the container.
DUMP_COMMAND="/usr/local/bin/forgejo-dump"

# The dump is ~22G; keep a safety margin on the staging disk.
MIN_FREE_GB=50

# Set to 1 only when the whole script succeeded; the exit trap
# removes a half-written dump otherwise.
BACKUP_SUCCEEDED=0

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
  local free_gb

  # The backup cycle creates the staging folder before calling us.
  if [ ! -d "$DESTINATION_DIR" ]; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] Staging directory not found: $DESTINATION_DIR"
    return 1
  fi

  if [ ! -w "$DESTINATION_DIR" ]; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] Destination directory is not writable: $DESTINATION_DIR"
    return 1
  fi

  DESTINATION_DIR=$(realpath -e -- "$DESTINATION_DIR") || return 1

  # df --output=avail -BG prints free space in GB; tail -1 skips the
  # header line; tr -dc '0-9' keeps only the digits ("498G" -> "498").
  free_gb=$(df --output=avail -BG "$DESTINATION_DIR" | tail -1 | tr -dc '0-9')

  if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] Only ${free_gb}G free in $DESTINATION_DIR (need ${MIN_FREE_GB}G)"
    return 1
  fi

  echo "$(date) [INFO] [FORGEJO_CHECK] Staging directory OK: $DESTINATION_DIR (${free_gb}G free)"
  return 0
}

check_requirements() {
  if ! command -v tar >/dev/null 2>&1; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] tar command not found"
    return 1
  fi

  if [ ! -x "$DUMP_COMMAND" ]; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] Dump helper not found or not executable: $DUMP_COMMAND"
    return 1
  fi

  # sudo -l <command> succeeds only if the sudoers rule allows it.
  # -n: never ask for a password (fail instead), since this runs unattended.
  if ! sudo -n -l "$DUMP_COMMAND" >/dev/null 2>&1; then
    echo "$(date) [ERROR] [FORGEJO_CHECK] sudo rule missing: $(whoami) may not run $DUMP_COMMAND"
    return 1
  fi

  echo "$(date) [INFO] [FORGEJO_CHECK] Dump helper and sudo rule OK"
  return 0
}

create_forgejo_dump() {
  TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
  DUMP_NAME="forgejo-dump-${TIMESTAMP}.tar"
  HOST_DUMP="${DESTINATION_DIR}/${DUMP_NAME}"

  echo "$(date) [INFO] [FORGEJO_DUMP] Creating live dump: $DUMP_NAME"
  echo -e "\n--- DUMP ---" >>"$FORGEJO_LOG"

  # Plain tar (not compressed): restic compresses and deduplicates it,
  # so only changed data is stored each night.
  #
  # The helper runs as root and writes the tar to stdout (>). This
  # script (forgejo-backup) creates the file, so it owns it.
  # Forgejo's own log lines go to stderr (2>>) and end up in our log.
  # (ShellCheck SC2024 warns that sudo doesn't apply to redirects; here
  # that is exactly what we want: root never writes to our staging dir.)
  # shellcheck disable=SC2024
  if ! sudo -n "$DUMP_COMMAND" \
    >"$HOST_DUMP" \
    2>>"$FORGEJO_LOG"; then

    echo "$(date) [ERROR] [FORGEJO_DUMP] Forgejo dump creation failed (see $FORGEJO_LOG)"
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

failure_cleanup() {
  # An incomplete or invalid dump must not end up in the next restic
  # snapshot; the log keeps the details.
  if [ -n "${HOST_DUMP:-}" ] && [ -f "$HOST_DUMP" ]; then
    rm -f -- "$HOST_DUMP"
    echo "$(date) [INFO] [FORGEJO_CLEANUP] Removed failed dump: $HOST_DUMP"
  fi
}

on_exit() {
  if [ "$BACKUP_SUCCEEDED" -ne 1 ]; then
    failure_cleanup
  fi
}

# Clean up a half-written dump however the script ends (error, Ctrl-C, kill).
trap 'on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main() {
  start_new_forgejo_log

  check_dir || return $?
  check_requirements || return $?
  create_forgejo_dump || return $?

  echo "$(date) [INFO] [FORGEJO_SYSTEM] Forgejo backup artifact ready: $HOST_DUMP"
  return 0
}

if main; then
  BACKUP_SUCCEEDED=1
  exit 0
else
  exit_code=$?

  echo "$(date) [ERROR] [FORGEJO_SYSTEM] Forgejo backup preparation failed (exit_code=$exit_code)"

  exit "$exit_code"
fi
