#!/bin/bash
#
# Checks that <dir> holds exactly one readable Forgejo dump with the expected contents.
# Read-only: never changes anything in <dir>.

set -u

. "$(dirname -- "$(realpath -- "$0")")/../../load-env.sh" || exit 1

require_env LOG_DIR

CHECK_DIR="${1:?Usage: $0 <dir>}"
FORGEJO_LOG="$LOG_DIR/forgejo_output.log"

find_dump() {
  echo -e "\n--- Verifying Dump ---" >>"$FORGEJO_LOG"
  local dumps
  local dump_count

  if [ ! -d "$CHECK_DIR" ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Not a directory: $CHECK_DIR"
    return 1
  fi

  # Only files directly in CHECK_DIR whose name matches the dump pattern.
  dumps=$(find "$CHECK_DIR" -maxdepth 1 -type f -name 'forgejo-dump-*.tar')

  # Count non-empty lines (no matches = 0).
  dump_count=$(grep -c . <<<"$dumps")

  if [ "$dump_count" -eq 0 ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] No Forgejo dump found in: $CHECK_DIR"
    return 1
  fi

  if [ "$dump_count" -gt 1 ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Expected 1 Forgejo dump, found $dump_count in: $CHECK_DIR"
    return 1
  fi

  DUMP_FILE=$dumps

  if [ ! -r "$DUMP_FILE" ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Dump is not readable: $DUMP_FILE"
    return 1
  fi

  if [ ! -s "$DUMP_FILE" ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Dump is empty: $DUMP_FILE"
    return 1
  fi

  echo "$(date) [INFO] [FORGEJO_VERIFY] Dump found: $DUMP_FILE"
  echo "Dump Successfully found" >>"$FORGEJO_LOG"

  return 0
}

check_contents() {
  # "local" keeps these variables inside this function only.
  local entries
  local repository_entries

  # 1. Read the whole archive.
  # tar -tf lists every file in the tar. To do that it has to read the
  # archive from start to end, so a cut-off or corrupted file fails here.
  # The list is saved in $entries so the checks below don't re-read the tar.
  # Errors from tar (2>) go to the log, not the screen.
  if entries=$(tar -tf "$DUMP_FILE" 2>>"$FORGEJO_LOG"); then
    echo "TAR integrity: OK" >>"$FORGEJO_LOG"
  else
    echo "$(date) [ERROR] [FORGEJO_VERIFY] TAR integrity check failed: $DUMP_FILE"
    return 1
  fi

  # 2. Config file needed to start a restored Forgejo.
  # <<<"$entries" feeds the saved list into grep.
  # -q: print nothing, just succeed or fail. -x: the whole line must match,
  # so "app.ini" matches but "custom/app.ini.bak" doesn't.
  if ! grep -qx 'app.ini' <<<"$entries"; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] app.ini not found in dump"
    return 1
  fi

  echo "found: app.ini" >>"$FORGEJO_LOG"

  # 3. Database export. Same check as above.
  if ! grep -qx 'forgejo-db.sql' <<<"$entries"; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] forgejo-db.sql not found in dump"
    return 1
  fi

  echo "found: forgejo-db.sql" >>"$FORGEJO_LOG"

  # 4. Git data. -c counts matching lines; ^ means "at the start of the line".
  # grep exits non-zero when the count is 0, so "|| true" stops that from
  # being treated as an error; the count itself is checked below.
  repository_entries=$(grep -c '^repos/' <<<"$entries" || true)

  if [ "$repository_entries" -eq 0 ]; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Repository data not found in dump"
    return 1
  fi

  echo "found: repos/ ($repository_entries entries)" >>"$FORGEJO_LOG"

  # 5. Paths that could escape the extract folder.
  # restore.sh extracts this tar as root, so an entry like "/etc/passwd"
  # or "../../etc/passwd" could overwrite system files.
  # ^/          an entry starting with /  (absolute path)
  # (^|/)\.\.(/|$)   ".." as a whole path part, e.g. "../x" or "a/../b"
  #                  (dots are escaped because . alone means "any character")
  if grep -qE '^/|(^|/)\.\.(/|$)' <<<"$entries"; then
    echo "$(date) [ERROR] [FORGEJO_VERIFY] Dump contains unsafe paths (absolute or ..)"
    return 1
  fi

  echo "paths: OK" >>"$FORGEJO_LOG"

  # 6. Record the checksum. Not a pass/fail check: it lets you prove later
  # that the file you restored is the same one that was verified.
  sha256sum "$DUMP_FILE" >>"$FORGEJO_LOG"

  echo "$(date) [INFO] [FORGEJO_VERIFY] Forgejo dump verified: $DUMP_FILE"
  return 0
}

main() {

  find_dump || return $?
  check_contents || return $?
}

if main; then
  exit 0
else
  exit_code=$?

  echo "$(date) [ERROR] [FORGEJO_VERIFY] Forgejo backup verification failed (exit_code=$exit_code)"
  exit "$exit_code"
fi
