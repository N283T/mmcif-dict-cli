# mmcif-dict-cli Design Spec

## Goal

A Zig CLI tool that searches and queries mmCIF PDBx dictionary definitions, enabling AI tools and humans to quickly look up categories, items, and their relationships.

## Architecture

PDBj provides a pre-parsed JSON representation of the mmCIF PDBx dictionary (`mmcif_pdbx.json.gz`). The CLI reads the decompressed JSON at runtime, builds an in-memory index, and serves queries against it.

```
data/mmcif_pdbx.json  (pre-decompressed, ~4.7MB)
        |
   Zig CLI binary (std.json parser -> in-memory model -> query)
```

## Data Source

- **File:** PDBj `mmcif_pdbx.json.gz` from `https://pdbj.org/`
- **Location:** `data/mmcif_pdbx.json` (decompressed)
- **Structure:** Single root key `data_mmcif_pdbx.dic` containing:
  - Top-level metadata (dictionary, dictionary_history, etc.)
  - `save_<name>` blocks for categories (e.g., `save_atom_site`)
  - `save__<category>.<item>` blocks for items (e.g., `save__atom_site.label_atom_id`)
  - `pdbx_item_linked_group` for cross-category relationships
- **Size:** ~7,370 save blocks, ~4.7MB uncompressed

## Commands

### `mmcif-dict category [NAME]`
- No argument: list all categories
- With argument: show category details (description, keys, groups, examples)

### `mmcif-dict item ITEM_NAME`
- Show item details: description, type, mandatory/optional, enumeration values
- Input format: `_atom_site.label_atom_id` or `atom_site.label_atom_id`

### `mmcif-dict relations CATEGORY`
- Show parent-child relationships for a category
- Uses `pdbx_item_linked_group` data

### `mmcif-dict search QUERY`
- Full-text search across category/item descriptions
- Case-insensitive substring match
- Returns matching categories and items with snippets

## Output Formats

- **Default:** Human-readable text
- **`--json` flag:** Machine-readable JSON (for skill/AI tool consumption)

## Known Constraints

- Zig 0.15.2 has gzip decompression bugs (ziglang/zig#24695, #25032, #25035)
  - Mitigation: use pre-decompressed JSON only; no runtime gzip
- JSON file path: check `$MMCIF_DICT_PATH` env var, fallback to `data/mmcif_pdbx.json` relative to executable

## File Structure

```
mmcif-dict-cli/
├── src/
│   ├── main.zig          # CLI entry point, argument parsing
│   ├── dict.zig          # Dictionary data model, query functions
│   ├── json_loader.zig   # JSON parsing, data structure construction
│   └── output.zig        # Text/JSON output formatting
├── test/
│   ├── dict_test.zig     # Unit tests for query functions
│   └── json_loader_test.zig  # Unit tests for JSON parsing
├── data/
│   ├── mmcif_pdbx.json.gz  # Source (gitignored)
│   └── mmcif_pdbx.json     # Decompressed (gitignored)
├── build.zig
├── build.zig.zon
├── .gitignore
└── README.md
```

## Future Extensions (not in scope)

- MCP Server mode
- Dictionary version comparison
- Custom dictionary support (IHM, ModelCIF, etc.)
- Skill for Claude Code integration
