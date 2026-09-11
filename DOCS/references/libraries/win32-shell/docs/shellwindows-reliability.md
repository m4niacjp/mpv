---
section: shellwindows-reliability
last_verified: 2026-09-11
claims:
  - "Shell.Application.Windows() returns a ShellWindows collection of all open shell windows; Item returns an InternetExplorer object"
  - "InternetExplorer.Document can be null ('if any'); Folder methods are not implemented for all folder types"
  - "Folder2.Self -> FolderItem.Path yields the native folder path; LocationURL is a file:/// URL that needs percent-decoding"
  - "IFolderView2::GetSortColumns requires a live shell view; SHGetViewStatePropertyBag is legacy and view state can be evicted"
  - "PowerShell 5.1 -File exit codes and -NoProfile -NonInteractive -ExecutionPolicy Bypass are documented; $OutputEncoding defaults to ASCII"
---

# ShellWindows / Document reliability

## Access chain (docs)

- `Shell.Application.Windows()` creates a `ShellWindows` object: "a collection
  of all of the open windows that belong to the Shell" (not only File Explorer).
  `Count` property; `Item` "Retrieves an InternetExplorer object that represents
  the Shell window".
  - https://learn.microsoft.com/en-us/windows/win32/shell/shell-windows
  - https://learn.microsoft.com/en-us/windows/win32/shell/shellwindows
- `InternetExplorer.Document`: "Gets the automation object of the active
  document, if any." (archived IE platform reference). Null and property-get
  failures must both be handled; there is no documented error contract.
  - https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa752084(v=vs.85)
- `ShellFolderView.Folder`: "Gets a Folder object that represents the view."
  `Folder2.Self` (Windows 2000+, Shell32 v5+): "Contains the folder's FolderItem
  object." `FolderItem.Path`: "Contains the item's full path and name."
  - https://learn.microsoft.com/en-us/windows/win32/shell/shellfolderview-folder
  - https://learn.microsoft.com/en-us/windows/win32/shell/folder2-self
  - https://learn.microsoft.com/en-us/windows/win32/shell/folderitem-path
- `Folder` object remark: "Not all methods are implemented for all folders...
  If you attempt to call an unimplemented method, a 0x800A01BD (decimal 445)
  error is raised." Special/virtual folders can therefore fail property access;
  guard every step with try/catch.
  - https://learn.microsoft.com/en-us/windows/win32/shell/folder

## Matching the folder

- Live probe (Windows 11, PS 5.1, read-only, 2026-09-11; paths anonymized):
  `LocationURL` = `file:///I:/example`, `Document.Folder.Self.Path` =
  `I:\example`, `Document.SortColumns` = `prop:System.ItemNameDisplay;`.
- Prefer `Folder.Self.Path` for local file folders: it is the native path with
  no URI escaping. `LocationURL` is "the URL of the resource that is currently
  displayed"; for file folders it is a `file:///` URL that must be
  percent-decoded (spaces, non-ASCII) before comparison.
- Virtual folders have no file-system path; either property can yield a shell
  namespace value (`::{GUID}`-style). No documented guarantee; treat as
  no-match and fall back.
- Multiple windows on the same folder: ShellWindows order is not documented;
  choose first match or an explicit preference; do not assume uniqueness.

## Elevation / UIPI

- UIPI "prevents a lower-privileged program from controlling the
  higher-privileged process" via window messages. The InternetExplorer docs note
  that a separate `CLSID_InternetExplorerMedium` exists to create IE at medium
  integrity. Cross-integrity behavior of ShellWindows COM automation is not
  documented. Practical rules: run the helper at the same integrity level as
  Explorer, catch per-window failures, and fall back. If Explorer runs elevated
  and the helper does not, expect missing/failing windows rather than a
  documented error.
  - https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/disable-user-account-control
  - InternetExplorer object remarks (link above)

## Alternatives considered

- `IFolderView2::GetSortColumns` (shobjidl_core.h, Vista+):
  `HRESULT GetSortColumns([out] SORTCOLUMN *rgSortColumns, [in] int cColumns);`
  with `SORTCOLUMN { PROPERTYKEY propkey; SORTDIRECTION direction; }`; the
  "Name" column property key is documented as `PKEY_ItemNameDisplay`. This is
  callable only from code holding a live shell view's `IFolderView2`
  (in-process shell view/namespace extension), which a plain PowerShell helper
  talking to an open window does not have.
  - https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifolderview2-getsortcolumns
  - https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ns-shobjidl_core-sortcolumn
  - Docs defect: the published SORTCOLUMN page swaps the
    SORT_ASCENDING/SORT_DESCENDING description sentences; rely on the enum
    names, not those sentences.
- `SHGetViewStatePropertyBag` (shlwapi.h): "available for use in the operating
  systems specified in the Requirements section. It may be altered or
  unavailable in subsequent versions." It appears in Deprecated Shell APIs.
  "The system keeps only a limited number of view states. If a folder is not
  visited for a long time, its view state is eventually deleted." The sort
  value's format inside the bag is not publicly documented, and calling it from
  PowerShell needs P/Invoke (Add-Type) or ShellBag registry knowledge.
  - https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-shgetviewstatepropertybag
  - https://learn.microsoft.com/en-us/windows/win32/shell/deprecated-api
- ShellBag registry (`HKCU\...\Shell\BagMRU` / `Bags`): not documented by
  Microsoft; binary, versioned, and staleness-prone. Not used.

## PowerShell 5.1 invocation notes

- Invocation:
  `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <script.ps1> <folder>`.
  All four switches are documented in about_PowerShell_exe (5.1);
  `-ExecutionPolicy Bypass` sets the session policy only (no registry change);
  `-NonInteractive` turns prompts into statement-terminating errors instead of
  hangs.
- `-File` exit codes: successful execution = 0; `exit N` sets the process exit
  code to N; a script-terminating error = 1. Use `exit 0` for "no match" and a
  distinct nonzero only if the caller must distinguish failure from no-match.
- Encoding: `$OutputEncoding` defaults to `ASCIIEncoding` in Windows PowerShell
  5.1 and governs data piped into native applications; `[Console]::OutputEncoding`
  governs the child's own stdout. Property tokens are pure ASCII and survive any
  of these settings. If the helper also prints non-ASCII paths, set UTF-8
  explicitly on the writing side and decode as UTF-8 in the consumer.
- No `Add-Type` is required: `New-Object -ComObject Shell.Application` plus
  property access uses built-in COM interop. Avoiding `Add-Type` keeps startup
  fast and avoids compile/scope issues.
- Sources: about_PowerShell_exe (5.1), about_Preference_Variables (5.1),
  about_Character_Encoding (5.1).

## Windows 11 quirks

- Microsoft docs record no disagreement between `Document.SortColumns` and the
  visible sort. The live Windows 11 probe returned a well-formed value.
  Community bug-report evidence was not collected here; a web-search pass is
  the right owner for that.
