# Sources

Each system we back up is a "source" with its own folder: `sources/<name>/`.

The backup cycle gives each source an empty staging folder to write into,
then handles restic, the S3 upload and cleanup itself. A source only has
to produce a good backup and be able to check it.

## Files every source needs

### backup.sh <staging-dir>

Writes everything needed to restore the service into `<staging-dir>`.

- `<staging-dir>` already exists, is empty, and has permissions 700.
  It is always `$BACKUP_DIR/<name>`, because restic groups snapshots
  by path for retention.
- Must leave the service in the state it found it (e.g. running),
  even if the backup fails.
- Exit 0 only when the backup is complete.
- If restic fails, the staging folder is kept for investigation, and
  the next run of this source stops until someone checks and removes it.

### verify.sh <dir>

Checks that the backup in `<dir>` is complete and readable
(e.g. the tar opens, expected files are present).

- Called on the staging folder after `backup.sh`, and on the restored
  folder after a restic restore.
- Must not create, change or delete anything in `<dir>`.
- Exit 0 only if the backup can be relied on for a restore.

### restore.sh <restored-dir> <recovery-dir> (optional)

Starts a temporary test instance from the restored backup, so a person
can check it.

- Must not touch the production service.
- Exit 0 once the test instance is up.
- Run it through the restore cycle:
  `./source-code-restore-cycle.sh <source> <snapshot-id>`
  (restores the snapshot, runs `verify.sh`, then `restore.sh` with sudo).

### source.env

Settings only this source uses, e.g. `FORGEJO_CONTAINER`.

- Shared settings (restic, rclone, logs) stay in `backup.env`.
- The restore cycle loads this file, so `RESTORE_DIR` and `RECOVERY_DIR`
  can be set here per source.

## Rules

- Only write inside `<staging-dir>` (or `<recovery-dir>` for `restore.sh`).
- Files containing secrets must be 600 or stricter.
- Log lines are tagged with the source name, e.g. `[FORGEJO_BACKUP]`.
- Exit 0 on success, non-zero on failure, with a message saying why.

## Adding a new source

1. Create `sources/<name>/` with `backup.sh`, `verify.sh` and `source.env`.
2. Add `restore.sh` if the backup can be started as a test instance.
3. Add `<name>` to `SOURCES` in `backup.env`.
4. Run a backup cycle and a restore cycle, and confirm both pass.
