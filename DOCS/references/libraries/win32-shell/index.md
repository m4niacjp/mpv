---
library: Windows Shell API (Shell.Application / shldisp)
package_names: []
version_scope: "Windows 11 with Windows PowerShell 5.1; COM interfaces documented Windows Vista+"
context7_id: /websites/learn_microsoft_en-us_windows_win32_api
last_verified: 2026-09-12
---

# Windows Shell API (Shell.Application / shldisp)

Project usage: mpv helper scripts read the per-folder Explorer sort order via
`Shell.Application` -> `ShellWindows` -> `.Document.SortColumns`, mapping
`System.*` property names to sort modes, then map the result to mpv playlist
sort behavior.

## Sections

- [Explorer sort columns via Shell.Application](docs/sortcolumns.md) — last_verified: 2026-09-12 (incl. equal-key name tie-break)
- [ShellWindows / Document reliability](docs/shellwindows-reliability.md) — last_verified: 2026-09-11
