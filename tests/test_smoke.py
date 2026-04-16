#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest"]
# ///
"""Smoke test: verify the embedded dictionary is accessible via the CLI.

Runs the built binary against a fresh environment (no cache file, no env
vars) and checks that every top-level read command works end-to-end using
only the @embedFile'd default pdbx dictionary.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BINARY = PROJECT_ROOT.joinpath("zig-out", "bin", "mmcif-dict")


def _ensure_binary() -> None:
    if not BINARY.exists():
        subprocess.run(["zig", "build"], cwd=PROJECT_ROOT, check=True)


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    # Isolate from the user's real cache + env so we always exercise the
    # embedded fallback, not whatever is in ~/.config/mmcif-dict/.
    env = {k: v for k, v in os.environ.items() if k != "MMCIF_DICT_PATH"}
    env["XDG_CONFIG_HOME"] = "/nonexistent-xdg-dir-for-smoke-test"
    env["HOME"] = "/nonexistent-home-for-smoke-test"
    return subprocess.run(
        [str(BINARY), *args],
        capture_output=True,
        text=True,
        env=env,
    )


@pytest.fixture(scope="module", autouse=True)
def _build_once() -> None:
    _ensure_binary()


def test_embedded_pdbx_category_lookup() -> None:
    r = _run("category", "atom_site")
    assert r.returncode == 0, r.stderr
    assert "atom_site" in r.stdout
    assert "label_atom_id" in r.stdout


def test_embedded_pdbx_item_lookup() -> None:
    r = _run("item", "_atom_site.label_atom_id")
    assert r.returncode == 0, r.stderr
    assert "label_atom_id" in r.stdout
    assert "atom_site" in r.stdout


def test_embedded_pdbx_show_auto_detects_category() -> None:
    r = _run("show", "_atom_site")
    assert r.returncode == 0, r.stderr
    assert "Category: atom_site" in r.stdout


def test_embedded_pdbx_show_auto_detects_item() -> None:
    r = _run("show", "_atom_site.label_atom_id")
    assert r.returncode == 0, r.stderr
    assert "Item: _atom_site.label_atom_id" in r.stdout


def test_category_list_nonempty() -> None:
    r = _run("category")
    assert r.returncode == 0, r.stderr
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    assert len(lines) > 500, f"got {len(lines)} categories"


def test_json_output_parses() -> None:
    r = _run("--json", "category", "atom_site")
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert data["id"] == "atom_site"
    assert isinstance(data.get("items"), list)
    assert len(data["items"]) > 0


def test_unknown_name_reports_error() -> None:
    # --name ihm has no cache and no embedded fallback → should exit 1
    r = _run("--name", "ihm", "category", "atom_site")
    assert r.returncode != 0
    # Match on stable tokens so message tweaks don't break CI.
    assert "ihm" in r.stderr
    assert "not found" in r.stderr


def test_help_text_mentions_new_flags() -> None:
    r = _run("--help")
    assert r.returncode == 0, r.stderr
    assert "--name" in r.stdout
    assert "fetch" in r.stdout


def test_dict_flag_rejected_with_fetch() -> None:
    r = _run("--dict", "/tmp/x.mdict", "fetch", "--url", "https://example.com/x.dic")
    assert r.returncode != 0
    assert "--dict" in r.stderr
    assert "fetch" in r.stderr


def test_dict_flag_rejected_with_compile() -> None:
    r = _run("--dict", "/tmp/x.mdict", "compile", "/tmp/in.dic", "-o", "/tmp/out.mdict")
    assert r.returncode != 0
    assert "--dict" in r.stderr
    assert "compile" in r.stderr


def test_empty_name_flag_rejected() -> None:
    r = _run("--name=", "category", "atom_site")
    assert r.returncode != 0
    assert "--name" in r.stderr


def test_invalid_name_rejected() -> None:
    # Space is not in the allowed [A-Za-z0-9_-] set
    r = _run("--name", "foo bar", "category", "atom_site")
    assert r.returncode != 0
    assert "invalid" in r.stderr.lower()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
