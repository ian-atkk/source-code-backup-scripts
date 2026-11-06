#!/bin/bash
#
#Looks throught the repository on S3 and extend retention if needed.
set -u

. "$(dirname -- "$(realpath -- "$0")")/load-env.sh"

require_env S3_BUCKET S3_PREFIX AWS_PROFILE LOG_DIR \
  RETENTION_THRESHOLD_DAYS RETENTION_EXTEND_DAYS

RETENTION_LOG="$LOG_DIR/retention_output.log"
LOCK_FILE="/tmp/restic_backup.lock"

if ! mkdir -p "$(dirname "$RETENTION_LOG")"; then
  echo "$(date) [ERROR] [RETENTION_SYSTEM] Failed to create log directory"
  exit 1
fi

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
  echo "$(date) [WARNING] [RETENTION] Retention extend already running. Exiting."
  exit 1
fi

start_new_retention_log() {
  local bar

  bar=$(printf '#%.0s' {1..80})

  {
    printf '\n\n%s\n' "$bar"
    printf '##  RETENTION RUN  |  %-56s##\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n' "$bar"
    printf "\nThreshold Days: $RETENTION_THRESHOLD_DAYS"
    printf "\nExtend by: $RETENTION_EXTEND_DAYS days\n"
  } >>"$RETENTION_LOG"
}

script_exit_log() {
  local exit_code="$1"

  echo "$(date) [ERROR] [RETENTION] Stopping script (exit_code=$exit_code)"
}

NOW=$(date -u +%s)
THRESHOLD_TIME=$(($NOW + RETENTION_THRESHOLD_DAYS * 86400))
EXTEND_UNTIL=$(($NOW + RETENTION_EXTEND_DAYS * 86400))

NEW_DATE=$(date -u -d "@$EXTEND_UNTIL" +%Y-%m-%dT%H:%M:%SZ)

extend_retention() {

  local object="$1"
  local retain_until="$2"
  local err

  printf '%-7s %-25.25s %s -> %s\n' "EXTEND" "${object#"$S3_PREFIX"}" \
    "$(date -u -d "$retain_until" '+%Y-%m-%d %H:%M')" \
    "$(date -u -d "$NEW_DATE" '+%Y-%m-%d %H:%M')" >>"$RETENTION_LOG"

  if ! err=$(aws s3api put-object-retention --bucket "$S3_BUCKET" --key "$object" \
    --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$NEW_DATE\"}" 2>&1); then
    echo "$(date) [ERROR] [RETENTION] put failed for $object: $err" | tee -a "$RETENTION_LOG"
    return 1
  fi
}

check_retention() {
  echo "$(date) [INFO] [RETENTION] Beginning S3 Index Check"

  local checked=0 extended=0 skipped=0 failed=0
  printf '%-7s %-25s %s\n' "ACTION" "KEY" "RETAIN UNTIL (UTC)" >>"$RETENTION_LOG"
  while read -r key; do
    ((checked++))
    if [[ "$key" == "${S3_PREFIX}locks/"* ]]; then
      continue
    fi
    retain_until=$(aws s3api get-object-retention --bucket "$S3_BUCKET" --key "$key" \
      --query 'Retention.RetainUntilDate' --output text 2>&1)

    if [ $? -ne 0 ]; then
      echo "$(date) [ERROR] [RETENTION] get failed for $key: $retain_until" | tee -a "$RETENTION_LOG"
      failed=$((failed + 1))
      continue
    fi

    retain_until_s=$(date -u -d "$retain_until" +%s)

    if ((retain_until_s <= THRESHOLD_TIME)); then
      if extend_retention "$key" "$retain_until"; then
        extended=$((extended + 1))
      else
        failed=$((failed + 1))
      fi

    else
      skipped=$((skipped + 1))
      printf '%-7s %-25.25s %s\n' "SKIP" "${key#"$S3_PREFIX"}" \
        "$(date -u -d "$retain_until" '+%Y-%m-%d %H:%M')" >>"$RETENTION_LOG"
    fi

  done < <(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$S3_PREFIX" \
    --query 'Contents[].[Key]' --output text)
  echo "Checked $checked | extended $extended | skipped $skipped | failed $failed" >>"$RETENTION_LOG"
  echo "$(date) [INFO] [RETENTION] Checked $checked | extended $extended | skipped $skipped | failed $failed"

  if [ "$checked" -eq 0 ]; then
    echo "$(date) [ERROR] [RETENTION] No objects listed (list failed or prefix empty)" | tee -a "$RETENTION_LOG"
    return 1
  fi

  [ "$failed" -eq 0 ]
}



main() {
  local exit_code

  start_new_retention_log

  check_retention
}

if main; then
  notify-send \
    "Retention Extension" \
    "Retention extension completed successfully" \
    >/dev/null 2>&1 || true

  exit 0
else
  exit_code=$?

  notify-send \
    "Retention Extension Failed" \
    "Retention extension failed with exit code $exit_code" \
    >/dev/null 2>&1 || true

  exit "$exit_code"
fi
