---
section: sortcolumns
last_verified: 2026-09-12
claims:
  - "IShellFolderViewDual3::get_SortColumns returns sort column names as an out BSTR (automation string property SortColumns), shldisp.h, Windows Vista+"
  - "Microsoft Learn documents no string grammar for SortColumns; observed format is semicolon-delimited prop:<CanonicalName> tokens with optional +/- after prop:"
  - "Canonical column properties: System.ItemNameDisplay, System.DateModified, System.DateCreated, System.Size, System.Media.Duration"
  - "On equal primary-key values Explorer falls back to later SortColumns tokens (unflagged = ascending); verified live for System.DateModified ties resolving by System.ItemNameDisplay ascending"
---

# Explorer sort columns via Shell.Application

## Verified API identity

- `IShellFolderViewDual3::get_SortColumns` / `put_SortColumns`, header
  `shldisp.h` (Shldisp.idl), minimum client Windows Vista [desktop apps only].
  - https://learn.microsoft.com/en-us/windows/win32/api/shldisp/nf-shldisp-ishellfolderviewdual3-get_sortcolumns
  - https://learn.microsoft.com/en-us/windows/win32/api/shldisp/nf-shldisp-ishellfolderviewdual3-put_sortcolumns
- Documented signatures:
  `HRESULT get_SortColumns([out] BSTR *pbstrSortColumns);` and
  `HRESULT put_SortColumns([in] BSTR bstrSortColumns);`
- Automation surface: reachable from a ShellFolderView automation object as the
  string property `SortColumns`, obtained via
  `Shell.Application.Windows().Item(i).Document` (verified live on Windows 11 /
  PS 5.1). The shldisp `ShellFolderView` object page does not list `SortColumns`;
  it is documented only at the COM interface level.
- Documentation gap: the method pages say only "Gets the names of the columns
  used to sort the current folder." No separator, direction encoding, ordering,
  or limits are documented. The same is true of the Context7-indexed Microsoft
  Learn corpus (`/websites/learn_microsoft_en-us_windows_win32_api`, verified
  2026-09-11); no Learn page documents the string grammar.

## String format (observed; not formally documented)

Observed on Windows 11 + Windows PowerShell 5.1 (read-only probe, 2026-09-11)
and in wild examples supplied by the caller:

- Tokens are separated by `;`; a trailing `;` is normal.
- Each token is `prop:<CanonicalPropertyName>`.
- An optional direction flag follows `prop:` immediately: `-` = descending,
  `+` = ascending. No flag = ascending (probe: `prop:System.ItemNameDisplay;`
  for a default Name-ascending window).
- First token = primary sort column; later tokens = secondary/tie-breaker
  columns in precedence order, e.g.
  `prop:-System.DateModified;System.ItemNameDisplay;`.
- Wild examples: `prop:System.ItemNameDisplay;`,
  `prop:-System.DateModified;System.ItemNameDisplay;`,
  `prop:+System.ItemDate;...`.

Recommended parse (PowerShell 5.1):

```powershell
$tokens = @($sort -split ';' | Where-Object { $_ })   # drop empty entries
if ($tokens.Count -gt 0 -and $tokens[0] -match '^prop:(?<dir>[+-])?(?<name>.+)$') {
    $descending = $Matches['dir'] -eq '-'
    $name       = $Matches['name']          # match case-insensitively
}
```

- Canonical names use the `System.` prefix; compare case-insensitively.
- Unsupported primary column -> fall back (`System.ItemDate` can appear for
  generic/search folder views).
- Empty string: undocumented; treat as "no data" and fall back.

## Canonical property names (verified)

| Mode | Canonical name | PKEY | Type |
| --- | --- | --- | --- |
| name | `System.ItemNameDisplay` | `PKEY_ItemNameDisplay` (B725F130-47EF-101A-A5F1-02608C9EEBAC, propID 10) | String |
| mtime | `System.DateModified` | `PKEY_DateModified` (propID 14) | DateTime |
| ctime | `System.DateCreated` | `PKEY_DateCreated` (propID 15) | DateTime |
| size | `System.Size` | `PKEY_Size` (propID 12) | UInt64 |
| duration | `System.Media.Duration` | `PKEY_Media_Duration` (64440490-4C8B-11D1-8B70-080036B11A03, propID 3) | UInt64 (100 ns units) |

Sources (all under https://learn.microsoft.com/en-us/windows/win32/properties/):
`props-system-itemnamedisplay`, `props-system-datemodified`,
`props-system-datecreated`, `props-system-size`,
`props-system-media-duration`.

- `System.Media.Duration` is the canonical duration property for audio and
  video. Explorer's visible header text ("Length", "Duration") is localized, so
  mapping must key off the canonical name, not the header text.
- `System.ItemDate` is an abstract "primary date" property used by some folder
  templates; not mapped in this project.

## Minimal helper pattern (Windows PowerShell 5.1)

```powershell
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($FolderPath).TrimEnd('\')
$shell  = New-Object -ComObject Shell.Application
foreach ($w in @($shell.Windows())) {
    try { $doc = $w.Document } catch { continue }
    if ($null -eq $doc) { continue }
    try { $folder = $doc.Folder } catch { continue }
    if ($null -eq $folder) { continue }
    try { $path = $folder.Self.Path } catch { continue }
    if (-not [string]::Equals($path.TrimEnd('\'), $target, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $sort = $doc.SortColumns
    if ([string]::IsNullOrEmpty($sort)) { break }   # empty -> fallback
    # parse $sort as above, emit an ASCII token, then break
    break
}
```

Enumeration, matching, and invocation caveats:
[shellwindows-reliability.md](shellwindows-reliability.md).

## Equal-key tie-break (verified live, 2026-09-11/12)

Sorting is lexicographic over the `SortColumns` token list: when the primary
column compares equal, Explorer uses the next token; an unflagged token is
ascending. Verified on a Windows 11 folder with Explorer sorted by
`System.DateModified` descending:

- Two files compared equal at mpv's second-resolution `mtime`
  (`mtime=1789160159` for both). Explorer showed the pair in
  `System.ItemNameDisplay` ascending order (`♥︎dr. …` before `You Never …`).
- The project helper previously broke the tie with the playlist index, which
  reversed that pair; after switching the tie-break to the same natural name
  comparison mpv uses for name sort, all 36 positions matched Explorer (34
  unchanged, only the tied pair swapped). Evidence and verification:
  `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\fix-validation.md` and
  `%APPDATA%\mpv\scripts\playlist-sort.lua` (`after_keys`: equal non-name keys
  -> name ascending -> playlist index).

Practical notes:

- Date ties are common for the helper because mpv's `utils.file_info` mtime
  has 1 s resolution; whether Explorer itself saw a true tie or a sub-second
  difference is not observable through the helper.
- The observed live `SortColumns` string exposed only the primary column, so
  the secondary column cannot be read from the API; the ascending name
  fallback is observed behavior, not a documented contract.

## Limits / open questions

- Undocumented: empty-string cases, icon/tile/list view modes, virtual folders
  (This PC, libraries, search results), and multiple windows on one folder.
- The `+`/`-` direction encoding is not in Microsoft docs; it is corroborated
  only by runtime examples. Keep a defensive default (ascending) and fall back
  on unparseable strings.
- Windows 11 disagreement between reported and visible sort is not covered by
  any Microsoft doc; one live Windows 11 window matched the expected format.
  Systematic quirk evidence would require web-search (community reports).
