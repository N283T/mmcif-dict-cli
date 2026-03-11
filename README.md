# mmcif-dict-cli

CLI tool for querying mmCIF PDBx dictionary definitions.

Uses PDBj's JSON representation of the mmCIF dictionary for fast lookups of categories, items, and their relationships.

## Setup

1. Build:

```bash
zig build -Doptimize=ReleaseFast
```

2. Download the dictionary:

```bash
mmcif-dict fetch
```

This downloads from PDBj and saves as `~/.config/mmcif-dict/mmcif_pdbx.json.gz` (~540 KB).
Decompression is handled natively at load time.

The binary is at `zig-out/bin/mmcif-dict`.

## Usage

```bash
# Download/update dictionary
mmcif-dict fetch

# List all categories (604 categories)
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
