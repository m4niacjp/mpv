---
name: project rules
description: Project-specific rules not otherwise indexed
type: project
---

## Source and docs

Verify implementation details against current source; user-visible behavior belongs in DOCS/man/.

## Build and tests

Use Meson. Prefer focused tests and the Windows targeted player build documented in AGENTS.md when runtime behavior is affected.
