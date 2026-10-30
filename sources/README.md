# Sources

Each thing we back up has its own folder: sources/<name>/

The backup cycle gives each source an empty folder to write into,
then handles restic, S3 upload and cleanup itself.

## Files every source needs

- backup.sh <staging-dir>
  Writes <source-code-dir> into <staging-dir>.
  Must leave the service running , even if the backup fails.

- verify.sh <dir>
  Checks that <staging-dir> is empty.
  Must not contain anything.

- restore.sh <restored-dir> <recovery-dir>   (optional)
  Starts restore so a person can check the backup.

- source.env
  Settings only this source uses, e.g. gitlab.env.

## Rules
- Only write inside ___ .
- Files containing secrets must be 400 (permissions).
- Exit 0 on success, 1 on failure.
s