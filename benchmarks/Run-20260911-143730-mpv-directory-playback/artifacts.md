# Retained artifacts

Raw logs, runtime samples, and the WPR plan remain outside Git under
`C:\Users\andre\PerfRuns`. No ETL, PML, dump, WPA export, or symbol cache was
created. SHA-256 values below identify the evidence used by `report.md`.

## Main directory run

Root: `C:\Users\andre\PerfRuns\mpv-directory-playback-20260911T073730633Z-bcc0a336932041f8a1322d0e783ce240`

| Relative path | SHA-256 |
| --- | --- |
| `manifest.json` | `429A23E13053BC3402EA8F7D85DC2A72141C571B8AADE37EEB27A3F717DD776C` |
| `environment.json` | `7D70C86862D379083E48F9E250551BEE8CDA10188617ACA48B7E9A237DFA6871` |
| `measurements\mpv-20260911-144226.log` | `242305BD9CADB146C3B6EC4C61BB6E9A08ABD9E9E1A80888093EA464CCADAAE0` |
| `measurements\runtime-20260911-144226.csv` | `D90A7B006FB27F0F1318716F2105DE0BB6D433596063F810BD9AB8F98EC38D91` |
| `measurements\mpv-corrected-20260911-144340.log` | `D93487D0D4A7DDC40B861AD48D958E56CAF90773E3F2A62ABC6420E6188D1A4E` |
| `measurements\runtime-corrected-20260911-144340.csv` | `FF12A26CE95350CEE0BBA7CEAC80A836E101330863C88EE1D863BD8F784CB8F4` |
| `measurements\wpr-plan-e895754d83564f70b1a0d1204266cb17.json` | `85A48AAB38E1E075BDA7ED09F028E33F615136F34FF0A9ECAE6D9D2E92A1AC82` |

## No-prefetch control

Root: `C:\Users\andre\PerfRuns\mpv-directory-no-prefetch-20260911T074451598Z-da46177d91294e89a23bf6cbd592dd8b`

| Relative path | SHA-256 |
| --- | --- |
| `manifest.json` | `D6A9CA52B089F6ED8B42BC7A95B034D2EC5F031799299DADEDFA10793769C970` |
| `measurements\mpv-20260911-144505.log` | `27E041D66E3B9E3845FADECE1835912F38F2EF0DEFABD20F1DA6C8B291FDA3A4` |
| `measurements\runtime-20260911-144505.csv` | `77F9F5332220361F4886F2B0BDF1EA142BFED44869084313E79A52844A7D5F19` |

## Single-file control

Root: `C:\Users\andre\PerfRuns\mpv-single-file-no-autocreate-20260911T074559707Z-577925d3602740a6a307f6ec645ffffd`

| Relative path | SHA-256 |
| --- | --- |
| `manifest.json` | `379B421698560D438926A3064698B787C0BECB98937AB976273976B412B727CC` |
| `measurements\mpv-20260911-144612.log` | `FF1A18D240833D55B6C0973888A854FAA45C4C3E3C00C0BA8EEEEACF155461E6` |
| `measurements\runtime-20260911-144612.csv` | `2BE3032D239950D0AA55C230B6EC80AD26FD4B6CFF2FA8E8E746B03777D0917D` |

Recompute a hash before relying on an artifact in a later session. A mismatch
means the retained evidence changed and prior conclusions require revalidation.
