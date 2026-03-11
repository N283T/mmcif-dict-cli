# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
