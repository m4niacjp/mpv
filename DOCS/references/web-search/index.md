# Web-search facets

Durable, cited external-evidence notes maintained by the `web-search` specialist.
One file per coherent claim/facet; not a session log.

| Facet | Retrieved | Summary |
| --- | --- | --- |
| [rclone-vfs-concurrent-read-starvation](docs/rclone-vfs-concurrent-read-starvation.md) | 2026-09-12 | rclone VFS `--vfs-cache-mode full` concurrent reads: chunk doubling at `--vfs-read-chunk-streams 0` is documented per open file; no external evidence of cross-file open starvation; mpv `prefetch-playlist` single-open-slot + blocking `cancel_open()` join verified in upstream v0.41.0 source. |
