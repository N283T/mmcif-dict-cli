#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""E2E tests for dict2json: convert mmcif_pdbx.dic and verify the output
is valid JSON that our tool can consume, producing results consistent
with the PDBj reference JSON."""

import gzip
import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BINARY = PROJECT_ROOT / "zig-out" / "bin" / "mmcif-dict"
PDBX_DIC = Path("/tmp/mmcif_pdbx.dic")
PDBJ_JSON_GZ = Path.home() / ".config" / "mmcif-dict" / "mmcif_pdbx.json.gz"


def _require_file(path: Path, hint: str) -> None:
    if not path.exists():
        pytest.skip(f"{path} not found. {hint}")


def _require_binary() -> None:
    if not BINARY.exists():
        subprocess.run(
            ["zig", "build"],
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
        )


def _run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(BINARY), *args],
        capture_output=True,
        text=True,
        **kwargs,
    )


@pytest.fixture(scope="module")
def converted_json(tmp_path_factory) -> dict:
    """Convert mmcif_pdbx.dic to JSON and return the parsed dict."""
    _require_binary()
    _require_file(PDBX_DIC, "Download from https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_pdbx.dic")

    result = _run(["dict2json", str(PDBX_DIC)])
    assert result.returncode == 0, f"dict2json failed: {result.stderr}"

    data = json.loads(result.stdout)
    return data


@pytest.fixture(scope="module")
def converted_json_file(converted_json, tmp_path_factory) -> Path:
    """Write converted JSON to a temp file for use with --dict."""
    tmp_dir = tmp_path_factory.mktemp("dict2json")
    path = tmp_dir / "pdbx_converted.json"
    path.write_text(json.dumps(converted_json))
    return path


@pytest.fixture(scope="module")
def pdbj_json() -> dict:
    """Load the PDBj reference JSON."""
    _require_file(PDBJ_JSON_GZ, "Run 'mmcif-dict fetch' first")
    with gzip.open(PDBJ_JSON_GZ, "rt") as f:
        return json.load(f)


# --- JSON validity ---


class TestJsonValidity:
    def test_output_is_valid_json(self, converted_json):
        """The output must be parseable JSON."""
        assert isinstance(converted_json, dict)

    def test_has_single_root_key(self, converted_json):
        """PDBj format: single root key = dictionary block name."""
        assert len(converted_json) == 1
        root_key = next(iter(converted_json))
        assert "pdbx" in root_key.lower() or "mmcif" in root_key.lower()

    def test_root_contains_save_frames(self, converted_json):
        root = next(iter(converted_json.values()))
        save_keys = [k for k in root if k.startswith("save_")]
        assert len(save_keys) > 100, f"Expected 100+ save frames, got {len(save_keys)}"


# --- Consistency with PDBj reference ---


class TestPdbjConsistency:
    def _our_root(self, converted_json):
        return next(iter(converted_json.values()))

    def _pdbj_root(self, pdbj_json):
        return next(iter(pdbj_json.values()))

    def test_category_count_matches(self, converted_json, pdbj_json):
        """Category count must match PDBj reference."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        our_cats = sorted(k for k in our if k.startswith("save_") and not k.startswith("save__"))
        ref_cats = sorted(k for k in ref if k.startswith("save_") and not k.startswith("save__"))

        assert len(our_cats) == len(ref_cats), (
            f"Category count: ours={len(our_cats)}, PDBj={len(ref_cats)}"
        )

    def test_item_count_matches(self, converted_json, pdbj_json):
        """Item count must match PDBj reference."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        our_items = sorted(k for k in our if k.startswith("save__"))
        ref_items = sorted(k for k in ref if k.startswith("save__"))

        assert len(our_items) == len(ref_items), (
            f"Item count: ours={len(our_items)}, PDBj={len(ref_items)}"
        )

    def test_category_names_match(self, converted_json, pdbj_json):
        """All category names must match."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        our_cats = {k for k in our if k.startswith("save_") and not k.startswith("save__")}
        ref_cats = {k for k in ref if k.startswith("save_") and not k.startswith("save__")}

        missing = ref_cats - our_cats
        extra = our_cats - ref_cats

        assert not missing, f"Missing categories: {sorted(missing)[:10]}"
        assert not extra, f"Extra categories: {sorted(extra)[:10]}"

    def test_item_names_match(self, converted_json, pdbj_json):
        """All item names must match."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        our_items = {k for k in our if k.startswith("save__")}
        ref_items = {k for k in ref if k.startswith("save__")}

        missing = ref_items - our_items
        extra = our_items - ref_items

        assert not missing, f"Missing items (first 10): {sorted(missing)[:10]}"
        assert not extra, f"Extra items (first 10): {sorted(extra)[:10]}"

    def test_category_id_values_match(self, converted_json, pdbj_json):
        """category.id must match for all categories."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        mismatches = []
        for key in ref:
            if not key.startswith("save_") or key.startswith("save__"):
                continue
            ref_id = ref[key].get("category", {}).get("id", [None])[0]
            our_id = our.get(key, {}).get("category", {}).get("id", [None])[0]
            if ref_id != our_id:
                mismatches.append((key, ref_id, our_id))

        assert not mismatches, f"category.id mismatches (first 5): {mismatches[:5]}"

    def test_item_category_id_values_match(self, converted_json, pdbj_json):
        """item.category_id must match for all items."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        mismatches = []
        for key in ref:
            if not key.startswith("save__"):
                continue
            ref_cat = ref[key].get("item", {}).get("category_id", [None])[0]
            our_cat = our.get(key, {}).get("item", {}).get("category_id", [None])[0]
            if ref_cat != our_cat:
                mismatches.append((key, ref_cat, our_cat))

        assert not mismatches, f"item.category_id mismatches (first 5): {mismatches[:5]}"

    def test_atom_site_items_count(self, converted_json, pdbj_json):
        """atom_site should have 103 items in both."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        our_atom_items = [k for k in our if k.startswith("save__atom_site.")]
        ref_atom_items = [k for k in ref if k.startswith("save__atom_site.")]

        assert len(our_atom_items) == len(ref_atom_items), (
            f"atom_site items: ours={len(our_atom_items)}, PDBj={len(ref_atom_items)}"
        )

    def test_relations_present(self, converted_json, pdbj_json):
        """pdbx_item_linked_group_list must be present with matching row count."""
        our = self._our_root(converted_json)
        ref = self._pdbj_root(pdbj_json)

        ref_rels = ref.get("pdbx_item_linked_group_list", {})
        our_rels = our.get("pdbx_item_linked_group_list", {})

        assert "child_name" in our_rels, "Missing child_name in relations"
        ref_count = len(ref_rels.get("child_name", []))
        our_count = len(our_rels.get("child_name", []))
        assert our_count == ref_count, f"Relation rows: ours={our_count}, PDBj={ref_count}"


# --- Tool integration (our JSON is loadable) ---


class TestToolIntegration:
    def test_category_list(self, converted_json_file):
        """'category' command must list 604 categories."""
        _require_binary()
        result = _run(["--dict", str(converted_json_file), "category"])
        assert result.returncode == 0
        categories = result.stdout.strip().split("\n")
        assert len(categories) == 604, f"Expected 604 categories, got {len(categories)}"

    def test_category_detail(self, converted_json_file):
        """'category atom_site' must show details."""
        result = _run(["--dict", str(converted_json_file), "category", "atom_site"])
        assert result.returncode == 0
        assert "Category: atom_site" in result.stdout
        assert "Items (103):" in result.stdout

    def test_item_detail(self, converted_json_file):
        """'item _atom_site.id' must show details."""
        result = _run(["--dict", str(converted_json_file), "item", "_atom_site.id"])
        assert result.returncode == 0
        assert "Item: _atom_site.id" in result.stdout
        assert "Category: atom_site" in result.stdout

    def test_relations(self, converted_json_file):
        """'relations atom_site' must return results."""
        result = _run(["--dict", str(converted_json_file), "relations", "atom_site"])
        assert result.returncode == 0
        assert "Relations for: atom_site" in result.stdout
        lines = [l for l in result.stdout.split("\n") if "<-" in l]
        assert len(lines) > 10, f"Expected 10+ relations, got {len(lines)}"

    def test_search(self, converted_json_file):
        """'search electron' must return results."""
        result = _run(["--dict", str(converted_json_file), "search", "electron"])
        assert result.returncode == 0
        assert "Items" in result.stdout

    def test_json_output(self, converted_json_file):
        """'--json category atom_site' must produce valid JSON."""
        result = _run(["--dict", str(converted_json_file), "--json", "category", "atom_site"])
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert data["id"] == "atom_site"
