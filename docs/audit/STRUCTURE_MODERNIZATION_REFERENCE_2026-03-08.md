# Structure Modernization Reference

Date: 2026-03-08

## Translation Guide

| Current name | Target name |
| --- | --- |
| prior Rust bounded-context namespace | `core/capacitor-core/src/contexts/` |
| prior Rust shell/composition type | `ContextServices` |
| prior repo-level governance surface | `architecture/` |

## Modernization Rules

- Do not preserve migration-shaped names in live production code just because they are already wired.
- Rust code and current governance surfaces should use permanent names only.
- Historical docs may retain historical narrative, but current docs, guards, and CI should not.
