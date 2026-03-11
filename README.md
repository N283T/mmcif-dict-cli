# mmcif-dict-cli

[![CI](https://github.com/N283T/mmcif-dict-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/N283T/mmcif-dict-cli/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/N283T/mmcif-dict-cli)](https://github.com/N283T/mmcif-dict-cli/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.2-f7a41d.svg)](https://ziglang.org/)
[![Nix](https://img.shields.io/badge/nix-flake-5277C3.svg)](https://nixos.org/)

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

## Examples

### List categories

```
$ mmcif-dict category | head
array_data
array_intensities
array_structure
array_structure_list
array_structure_list_axis
array_structure_list_section
atom_site
atom_site_anisotrop
atom_sites
atom_sites_alt
```

604 categories available in the PDBx dictionary.

### Category details

```
$ mmcif-dict category atom_site
Category: atom_site
Mandatory: no
Keys: _atom_site.id
Groups: inclusive_group, atom_group

Description:
Data items in the ATOM_SITE category record details about
the atom sites in a macromolecular crystal structure, such as
the positional coordinates, atomic displacement parameters,
magnetic moments and directions.
...

Items (103):
  _atom_site.aniso_B[1][1]
  _atom_site.aniso_B[1][1]_esd
  ...
```

### Item details

```
$ mmcif-dict item _atom_site.label_atom_id
Item: _atom_site.label_atom_id
Category: atom_site
Type: atcode
Mandatory: yes

Description:
A component of the identifier for this atom site.

This data item is a pointer to _chem_comp_atom.atom_id in the
CHEM_COMP_ATOM category.
```

### Relations

```
$ mmcif-dict relations atom_site | head -8
Relations for: atom_site

  _atom_site.label_asym_id <- _pdbx_branch_scheme.asym_id (child: pdbx_branch_scheme)
  _atom_site.label_comp_id <- _pdbx_branch_scheme.mon_id (child: pdbx_branch_scheme)
  _atom_site.auth_comp_id <- _pdbx_branch_scheme.pdb_mon_id (child: pdbx_branch_scheme)
  _atom_site.auth_seq_id <- _pdbx_branch_scheme.pdb_seq_num (child: pdbx_branch_scheme)
  _atom_site.pdbx_PDB_ins_code <- _pdbx_branch_scheme.pdb_ins_code (child: pdbx_branch_scheme)
  _atom_site.auth_asym_id <- _pdbx_branch_scheme.pdb_asym_id (child: pdbx_branch_scheme)
```

### Search

```
$ mmcif-dict search "electron density"
Categories (1):
  pdbx_dcc_map

Items (31):
  _pdbx_dcc_map.density_connectivity
  _pdbx_dcc_rscc_mapman.correlation
  _atom_sites_footnote.text
  _refine.pdbx_density_correlation
  ...
```

## Using with gemmi

You can also generate the dictionary JSON using [gemmi](https://gemmi.readthedocs.io/):

```bash
gemmi convert --to=mmjson mmcif_pdbx.dic mmcif_pdbx.json
mmcif-dict --dict mmcif_pdbx.json category
```

Both `dict2json` (built-in) and gemmi produce compatible JSON output.

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
