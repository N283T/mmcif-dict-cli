# mmcif-dict-cli

CLI tool for querying mmCIF PDBx dictionary definitions.

Uses PDBj's JSON representation of the mmCIF dictionary for fast lookups of categories, items, and their relationships.

## Setup

1. Download and decompress the PDBj dictionary JSON:

```bash
mkdir -p data
curl -o data/mmcif_pdbx.json.gz https://pdbj.org/dictionaries/mmcif_pdbx.json.gz
gunzip data/mmcif_pdbx.json.gz
```

2. Build:

```bash
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/mmcif-dict`.

## Usage

```bash
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

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format |
| `--dict PATH` | Path to `mmcif_pdbx.json` |
| `--help` | Show usage |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MMCIF_DICT_PATH` | Default path to `mmcif_pdbx.json` (overrides exe-relative lookup) |

## Data Source

Dictionary data from [PDBj](https://pdbj.org/) (`mmcif_pdbx.json.gz`), a JSON representation of the [wwPDB mmCIF PDBx dictionary](http://mmcif.pdb.org/).
