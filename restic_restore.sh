#!/bin/bash

# Restores one restic snapshot into an empty directory.

set -u

. "$(dirname -- "$(realpath -- "$0")")/load-env.sh"

require_env RESTIC_REPOSITORY RESTIC_PASSWORD_FILE LOG_DIR

SNAPSHOT_ID="${1:?Usage: $0 <snapshot-id> <target-directory>}"
RESTORE_DIR="${2:?Usage: $0 <snapshot-id> <target-directory>}"

RESTIC_LOG="$LOG_DIR/restic_output.log"

# Read from the snapshot in validate_snapshot (e.g. $BACKUP_DIR/forgejo).
SNAPSHOT_PATH=""

if ! mkdir -p "$(dirname "$RESTIC_LOG")"; then
  echo "$(date) [ERROR] [RESTIC_RESTORE] Failed to create log directory"
  exit 1
fi

check_requirements() {
  if ! command -v restic >/dev/null 2>&1; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] restic is not installed"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] jq is not installed"
    return 1
  fi

  if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] Password file is not readable: $RESTIC_PASSWORD_FILE"
    return 1
  fi

  return 0
}

prepare_restore_directory() {
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

validate_snapshot() {
  local snapshot_json

  if ! snapshot_json=$(restic snapshots --no-lock --json "$SNAPSHOT_ID" 2>>"$RESTIC_LOG"); then
    echo "$(date) [ERROR] [RESTIC_RESTORE] Snapshot not found: $SNAPSHOT_ID"
    return 1
  fi

  # Each backup cycle snapshots one staging folder, so a snapshot has one
  # path. Restoring "<id>:<path>" puts that folder's contents directly in
  # RESTORE_DIR instead of recreating the full path underneath it.
  SNAPSHOT_PATH=$(jq -r '.[0].paths[0] // empty' <<<"$snapshot_json")

  if [ -z "$SNAPSHOT_PATH" ]; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] Could not read the backed-up path of snapshot: $SNAPSHOT_ID"
    return 1
  fi

  echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot found: $SNAPSHOT_ID"
  return 0
}

restore_snapshot() {
  local exit_code

  echo "$(date) [INFO] [RESTIC_RESTORE] Restoring snapshot: $SNAPSHOT_ID"
  echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot path: $SNAPSHOT_PATH"
  echo "$(date) [INFO] [RESTIC_RESTORE] Restore target: $RESTORE_DIR"

  {
    printf '\n--- RESTORE ---\n'
    printf 'repository: %s\n' "$RESTIC_REPOSITORY"
    printf 'snapshot: %s\n' "$SNAPSHOT_ID"
  } >>"$RESTIC_LOG"

  restic restore --no-lock \
    "${SNAPSHOT_ID}:${SNAPSHOT_PATH}" \
    --target "$RESTORE_DIR" \
    >>"$RESTIC_LOG" 2>&1

  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [RESTIC_RESTORE] Snapshot restore failed (exit_code=$exit_code)"
    return "$exit_code"
  fi
  echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot successfully restored from: $RESTIC_REPOSITORY"
  echo "$(date) [INFO] [RESTIC_RESTORE] Snapshot successfully restored to: $RESTORE_DIR"
  return 0
}

main() {
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
