# rclone

- canonical: rclone
- aliases: rclone mount, rclone VFS, rclone serve
- ecosystem: go / cloud-storage CLI
- package_names: rclone
- context7_ids:
  - /websites/rclone (rclone.org docs mirror; trust 10; lastUpdate 2026-09-05; verified 2026-09-12)
  - /rclone/rclone (official source repo; trust 7.5; lastUpdate 2026-08-25; verified 2026-09-12)
- version_scope: no version-specific Context7 IDs; pinned build v1.76.0-beta.10339.ef6968730 (commit ef6968730, 2026-09-09); docs snapshots 4/15 days older, but the VFS chunked-reading text is identical to vfs/vfs.md at the pinned commit.
- project_reference: DOCS/references/libraries/rclone/index.md
- last_verified: 2026-09-12
- notes:
  - Prefer /websites/rclone for option semantics; /rclone/rclone carries MANUAL.txt and source.
  - "VFS Chunked Reading" lives in vfs/vfs.md and is embedded on mount/nfsmount/serve_* command pages; subsections keyed to --vfs-read-chunk-streams == 0 (sequential chunk doubling per open file) and > 0 (N concurrent constant-size chunks).
  - VFS docs document --transfers only as parallel uploads of write-cached files; no doc statement bounds VFS reads by it (not documented).
