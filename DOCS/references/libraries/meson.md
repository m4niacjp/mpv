---
library: Meson
package_names: [meson, mesonbuild]
version_scope: "mpv requires meson_version >=1.3.0; this checkout's python -m mesonbuild.mesonmain is 1.11.1; Context7 ID /mesonbuild/meson has no version-specific IDs"
context7_id: /mesonbuild/meson
last_verified: 2026-08-18
---

# Meson

Cross-platform build system used by this mpv checkout (`meson.build`).
Context7 ID: `/mesonbuild/meson` (fresh `ctx7 library meson` 2026-08-18;
`/mesonbuild/meson-python` is a different package). `versions` was empty.

## `b_coverage` (base option)

From Builtin-options.md: `b_coverage` defaults to **false** and enables
coverage tracking.

Configure:

```console
$ meson setup <other flags> -Db_coverage=true
```

## Compile, test, reports

From howtox.md (“Producing a coverage report”):

```console
$ meson compile
$ meson test
$ ninja coverage-html (or coverage-xml)
```

The report is in the `meson-logs` subdirectory.

From Unit-tests.md and Feature-autodetection.md:

- Enable with `-Db_coverage=true`, then generate reports **after tests**.
- Meson autodetection looks for **gcovr**, **lcov**, and **genhtml**.
- Generated targets (when tools/versions are found):
  - `coverage-xml`, `coverage-text`, `coverage-sonarqube` — **Gcovr**
  - `coverage-html` — **lcov/GenHTML or Gcovr**
  - `coverage` — all possible report types
- Reports require tests first so call information exists.

## Version notes (coverage)

- **0.55.0**: when Clang is the compiler, Meson uses **`llvm-cov`** for
  coverage information (Release-notes-for-0.55.0.md).
- **0.63.0**: coverage targets respect tool config files. If `gcovr.cfg` is
  in the source root (gcovr >= 4.2), Meson no longer auto-excludes
  `subprojects/`. If `.lcovrc` is in the source root, Meson tells lcov to
  use it (Release-notes-for-0.63.0.md).

## Documented gaps

- Context7 coverage docs do **not** state whether `b_coverage` works with
  MSVC or native Windows toolchains. Do not infer MSVC support from
  unrelated Builtin-options.md / Compiler-properties.md compiler tables.
- No version-specific Context7 IDs; do not mix silent version suffixes.
