# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Removed

- Embedded PDBx dictionary (`@embedFile`) — `mmcif-dict fetch` is now required
  on first use; binary shrinks from ~3 MB to ~1 MB
- Two-stage build (`compile_tool` host binary and `data/mmcif_pdbx.dic`)

### Changed

- Dictionary resolution falls through to a clear error message instead of an
  embedded fallback when no cache is found

## [0.2.0] - 2026-04-16

### Added

- `compile` command: convert CIF `.dic` dictionary files to native `.mdict` binary format
- Native `.mdict` binary format (zero-copy, sorted records, binary-search lookups)
- `fetch` now downloads `.dic` files from wwPDB and compiles them in-process
  into `.mdict` (no separate decompression step)
- `--name NAME` flag selects a named cache under `~/.config/mmcif-dict/<name>.mdict`
  (default `pdbx`); enables co-existing IHM, CIF core, and other dictionaries
- Default PDBx dictionary is embedded in the binary via `@embedFile` so
  `mmcif-dict category atom_site` works out of the box with no `fetch` step
- Two-stage build: a host-target `compile_tool` pre-compiles `data/mmcif_pdbx.dic`
  into the `.mdict` the main binary embeds
- E2E smoke tests (`tests/test_smoke.py`) run in CI

### Changed

- **Breaking**: `--dict` and `MMCIF_DICT_PATH` now accept `.mdict` only (previously `.json` / `.json.gz`)
- Runtime dictionary loader rewritten to use zero-copy view over `.mdict` buffer instead of arena + HashMap
- Fetch error messages now distinguish DNS / TLS / redirect / network / protocol failures and sniff HTML/XML/JSON responses for clearer diagnostics
- Cache names validated against a strict `[A-Za-z0-9_-]{1,64}` allowlist

### Removed

- **Breaking**: `dict2json` subcommand (use `gemmi convert` if you need PDBj-style JSON)
- **Breaking**: PDBj JSON dictionaries are no longer a supported input format; users must re-run `mmcif-dict fetch` or `mmcif-dict compile` to migrate existing caches
- JSON-based dictionary loader and `std.json` dependency
- PDBj JSON fixtures and test data

## [0.1.1] - 2025-03-11

### Added

- `show` command: auto-detect category or item based on dot notation
  - `show _atom_site` → category details
  - `show _atom_site.label_entity_id` → item details

### Changed

- `category` command now accepts leading `_` and item-style dot notation
  - `_atom_site` and `_atom_site.entity_id` both resolve to `atom_site`
- `relations` command now accepts leading `_` in category name

## [0.1.0] - 2025-03-11

### Added

- `category` command: list all categories or show details for a specific category
- `item` command: show item details (e.g., `_atom_site.label_atom_id`)
- `relations` command: show parent-child relationships for a category
- `search` command: full-text search across descriptions
- `fetch` command: download dictionary from PDBj with optional custom URL
- `dict2json` command: convert CIF dictionary files to PDBj-compatible JSON
- `--json` flag for machine-readable JSON output
- `--dict PATH` option to specify custom dictionary path
- `MMCIF_DICT_PATH` environment variable support
- Native gzip decompression for `.json.gz` dictionary files
- Native HTTP client for dictionary download (no external dependencies)
- CIF parser supporting data blocks, save frames, loops, multi-line strings, and quoted strings
- Support for gemmi mmJSON Frames format
- E2E tests validating dict2json output against PDBj reference JSON
