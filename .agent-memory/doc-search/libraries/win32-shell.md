# win32-shell

- canonical: Windows Shell API (Shell.Application automation + shldisp COM interfaces)
- aliases: Shell.Application, ShellWindows, ShellFolderView, IShellFolderViewDual3, Explorer sort, SortColumns
- ecosystem: Windows Win32 / COM automation (no package manager)
- package_names: none (OS API)
- context7_ids:
  - /websites/learn_microsoft_en-us_windows_win32_api (indexed mirror of Microsoft Learn Win32 API; verified 2026-09-11; 377k snippets)
- version_scope: Windows 11 + Windows PowerShell 5.1; shell interfaces documented Windows Vista+
- project_reference: DOCS/references/libraries/win32-shell/index.md
  (repo docs root is tracked as `DOCS/`; lower-case `docs/` resolves here on Windows)
- last_verified: 2026-09-11
- notes:
  - `IShellFolderViewDual3::get_SortColumns` is under `shldisp`, not `shobjidl_core`; the correct Learn URLs use `/windows/win32/api/shldisp/`.
  - Microsoft Learn documents no string grammar for SortColumns (separator/direction); rely on observed runtime format and keep defensive parsing.
  - URL discovery: https://learn.microsoft.com/api/search?search=<terms>&locale=en-us works well; webfetch accepts the JSON.
  - PowerShell 5.1 docs must use `?view=powershell-5.1`; default moniker redirects to 7.x otherwise.
