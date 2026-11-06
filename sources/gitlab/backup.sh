#!/bin/bash
#
#creates a tar dump in <staging-dir> for restic.
set -u
. "$(dirname -- "$(realpath -- "$0")")/../../load-env.sh" || exit 1
load_source_env gitlab
require_env GITLAB_DIR GITLAB_SERVICE GITLAB_CONTAINER GITLAB_UID LOG_DIR

DESTINATION_DIR="${1:?Usage: $0 <staging-dir>}"
GITLAB_LOG="$LOG_DIR/gitlab_output.log"

# Set to 1 only while this script has Forgejo stopped.
GITLAB_STOPPED_BY_US=0

if ! mkdir -p "$(dirname "$GITLAB_LOG")"; then
  echo "$(date) [ERROR] [GITLAB_SYSTEM] Failed to create log directory"
  exit 1
fi