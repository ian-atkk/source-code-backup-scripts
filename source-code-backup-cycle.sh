#!/bin/bash
#
# Runs one full backup cycle: each source in SOURCES writes a backup into
# its own staging folder, restic snapshots it, then the restic repo is
# mirrored offsite with rclone and the staging folders are deleted.

set -u

SCRIPT_DIR=$(dirname -- "$(realpath -- "$0")")

. "$SCRIPT_DIR/load-env.sh" || exit 1

require_env BACKUP_DIR LOCK_FILE SOURCES

# Only one cycle at a time: a source's backup may stop its service.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "$(date) [WARNING] [BACKUP_CYCLE] Backup cycle already running. Exiting."
  exit 1
fi

echo "$(date) [INFO] [BACKUP_CYCLE] Starting backup cycle (sources: $SOURCES)"

if ! mkdir -p -- "$BACKUP_DIR"; then
  echo "$(date) [ERROR] [BACKUP_CYCLE] Failed to create backup directory: $BACKUP_DIR"
  exit 1
fi

# Backs up one source. Returns non-zero if its snapshot was not created.
backup_source() {
  local source="$1"
  local source_dir="$SCRIPT_DIR/sources/$source"
  local staging_dir="$BACKUP_DIR/$source"
  local exit_code

  # The name becomes part of a path that is later deleted with rm -rf,
  # so only allow simple names (no "/", "..", spaces).
  case "$source" in
  "" | *[!a-z0-9_-]*)
    echo "$(date) [ERROR] [BACKUP_CYCLE] Invalid source name in SOURCES: '$source'"
    return 1
    ;;
  esac

  if [ ! -x "$source_dir/backup.sh" ] || [ ! -x "$source_dir/verify.sh" ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] backup.sh or verify.sh missing or not executable in: $source_dir"
    return 1
  fi

  # restic groups snapshots by path, so the staging folder keeps the same
  # path every night. A leftover one means an earlier run failed after
  # the backup was made; keep it for investigation instead of overwriting.
  if [ -e "$staging_dir" ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Staging folder left by an earlier run: $staging_dir"
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Check it, then remove it before the next run"
    return 1
  fi

  if ! mkdir -m 700 -- "$staging_dir"; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Failed to create staging folder: $staging_dir"
    return 1
  fi

  # Step 1: The source writes its backup into the staging folder.
  "$source_dir/backup.sh" "$staging_dir"
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Backup failed (exit_code=$exit_code)"
    rm -rf -- "$staging_dir"
    return "$exit_code"
  fi

  # Step 2: The source checks its own backup.
  "$source_dir/verify.sh" "$staging_dir"
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Unable to verify backup (exit_code=$exit_code)"
    rm -rf -- "$staging_dir"
    return "$exit_code"
  fi

  echo "$(date) [INFO] [BACKUP_CYCLE] [$source] Backup ready: $staging_dir"

  # Step 3: Protect the staging folder with restic.
  "$SCRIPT_DIR/restic_backup.sh" "$staging_dir"
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    # Keep the staging folder for investigation.
    echo "$(date) [ERROR] [BACKUP_CYCLE] [$source] Restic backup failed; retaining: $staging_dir"
    return "$exit_code"
  fi

  # Step 4: The backup is in restic now, so the staging copy can go.
  if ! rm -rf -- "$staging_dir"; then
    # The backup itself succeeded; the leftover folder only blocks the
    # next run, which reports it.
    echo "$(date) [WARNING] [BACKUP_CYCLE] [$source] Restic succeeded, but staging cleanup failed: $staging_dir"
  fi

  return 0
}

failed_sources=""
succeeded_count=0

# $SOURCES is left unquoted on purpose so "forgejo other" splits into
# one loop pass per name.
for source in $SOURCES; do
  echo "$(date) [INFO] [BACKUP_CYCLE] [$source] Starting source backup"

  if backup_source "$source"; then
    succeeded_count=$((succeeded_count + 1))
    echo "$(date) [INFO] [BACKUP_CYCLE] [$source] Source backup completed"
  else
    # Keep going: one broken source should not stop the others.
    failed_sources="$failed_sources $source"
  fi
done

# Step 5: Mirror the restic repository offsite, if anything new went in.
sync_exit_code=0

if [ "$succeeded_count" -gt 0 ]; then
  "$SCRIPT_DIR/rclone_sync.sh"
  sync_exit_code=$?

  if [ "$sync_exit_code" -ne 0 ]; then
    echo "$(date) [ERROR] [BACKUP_CYCLE] Offsite sync failed (exit_code=$sync_exit_code)"
  fi
else
  echo "$(date) [WARNING] [BACKUP_CYCLE] No source was backed up; skipping offsite sync"
fi

if [ -n "$failed_sources" ]; then
  echo "$(date) [ERROR] [BACKUP_CYCLE] Backup cycle finished with failed sources:$failed_sources"
  exit 1
fi

if [ "$sync_exit_code" -ne 0 ]; then
  echo "$(date) [WARNING] [BACKUP_CYCLE] Backup cycle finished, but offsite copy is out of date"
  exit "$sync_exit_code"
fi

echo "$(date) [INFO] [BACKUP_CYCLE] Backup cycle completed successfully"
exit 0
