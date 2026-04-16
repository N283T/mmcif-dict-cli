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

### Nix

```bash
# Run directly
nix run github:N283T/mmcif-dict-cli -- category atom_site

# Or install to profile
nix profile install github:N283T/mmcif-dict-cli
```

With Home Manager, add the flake input and package:

```nix
# flake.nix
inputs.mmcif-dict-cli = {
  url = "github:N283T/mmcif-dict-cli";
  inputs.nixpkgs.follows = "nixpkgs";
};

# home.nix or dev.nix
home.packages = [
  inputs.mmcif-dict-cli.packages.${system}.default
];
```

### Build from source

Requires [Zig](https://ziglang.org/) 0.15.2+.

```bash
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/mmcif-dict`.

## Quick Start

```bash
# Download the default PDBx dictionary (~5 MB, required on first use)
mmcif-dict fetch

# List all 604 categories
mmcif-dict category

# Auto-detect and show category or item
mmcif-dict show _atom_site
mmcif-dict show _atom_site.label_atom_id

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

# Fetch an alternate dictionary into its own cache
mmcif-dict fetch --name ihm --url https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_ihm.dic
mmcif-dict --name ihm category <ihm_category>

# Compile a CIF dictionary to the native .mdict binary yourself
mmcif-dict compile mmcif_pdbx.dic -o mmcif_pdbx.mdict
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

## Dictionary Path Resolution

The dictionary source is resolved in this order:

1. `--dict PATH` command-line option (`.mdict`)
2. `$MMCIF_DICT_PATH` environment variable
3. `~/.config/mmcif-dict/<name>.mdict` (installed by `fetch`; `<name>` comes
   from `--name NAME` and defaults to `pdbx`)

If no dictionary is found, the CLI prints an error directing you to run
`mmcif-dict fetch`.

The runtime format is a zero-copy native binary (`.mdict`). Produce one with
`mmcif-dict compile` or `mmcif-dict fetch`.

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format |
| `--dict PATH` | Path to dictionary (`.mdict`) |
| `--name NAME` | Select named cache (default: `pdbx`) |
| `--help` | Show usage |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MMCIF_DICT_PATH` | Default path to a `.mdict` file (overrides named-cache lookup and the embedded default) |

## Data Source

Dictionary data originates from the [wwPDB mmCIF PDBx dictionary](http://mmcif.pdb.org/).
Run `mmcif-dict fetch` to download and compile the default PDBx dictionary
to `~/.config/mmcif-dict/pdbx.mdict`. Other dictionaries can be installed as
named caches via `mmcif-dict fetch --name NAME --url <URL>` or produced
locally with `mmcif-dict compile input.dic -o out.mdict`.

## License

[MIT](LICENSE)
