# mmcif-dict-cli

CLI tool for querying mmCIF PDBx dictionary definitions.

Uses PDBj's JSON representation of the mmCIF dictionary for fast lookups of categories, items, and their relationships.

## Installation

### Pre-built binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/N283T/mmcif-dict-cli/main/install.sh | sh
```

Installs to `~/.local/bin/` by default. Override with `INSTALL_DIR`:

```bash
INSTALL_DIR=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/N283T/mmcif-dict-cli/main/install.sh | sh
```

Supported platforms: Linux (x86_64, aarch64), macOS (aarch64).

### Build from source

Requires [Zig](https://ziglang.org/) 0.15.2+.

```bash
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/mmcif-dict`.

## Quick Start

```bash
# Download the dictionary (~540 KB)
mmcif-dict fetch

# List all 604 categories
mmcif-dict category

# Show category details
mmcif-dict category atom_site

# Show item details
mmcif-dict item _atom_site.label_atom_id

# Show parent-child relationships
mmcif-dict relations atom_site

# Full-text search across descriptions
mmcif-dict search "electron density"

# JSON output (for AI tools / scripts)
mmcif-dict --json category atom_site

# Convert CIF dictionary to PDBj-compatible JSON
mmcif-dict dict2json mmcif_pdbx.dic
```

## Dictionary Path Resolution

The dictionary file is resolved in this order:

1. `--dict PATH` command-line option (`.json` or `.json.gz`)
2. `$MMCIF_DICT_PATH` environment variable
3. `~/.config/mmcif-dict/mmcif_pdbx.json.gz` (installed by `fetch`)
4. `<exe_dir>/../data/mmcif_pdbx.json` (development fallback)

Files ending in `.gz` are decompressed automatically using Zig's native flate implementation.

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format |
| `--dict PATH` | Path to dictionary (`.json` or `.json.gz`) |
| `--help` | Show usage |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MMCIF_DICT_PATH` | Default path to `mmcif_pdbx.json` (overrides config/exe-relative lookup) |

## Data Source

Dictionary data from [PDBj](https://pdbj.org/) (`mmcif_pdbx.json.gz`), a JSON representation of the [wwPDB mmCIF PDBx dictionary](http://mmcif.pdb.org/).

## License

[MIT](LICENSE)
