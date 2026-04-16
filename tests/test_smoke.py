#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest"]
# ///
"""Smoke test: verify the CLI works against a compiled fixture dictionary.

Compiles tests/fixtures/minimal.dic into an .mdict file once per module,
then passes --dict <path> to every invocation. Cache and env isolation is
kept so tests never accidentally pick up the user's real config.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BINARY = PROJECT_ROOT.joinpath("zig-out", "bin", "mmcif-dict")
FIXTURE_DIC = PROJECT_ROOT.joinpath("tests", "fixtures", "minimal.dic")

# Set by the module-scoped fixture; used by _run_with_dict().
_compiled_mdict: Path | None = None


def _ensure_binary() -> None:
    if not BINARY.exists():
        subprocess.run(["zig", "build"], cwd=PROJECT_ROOT, check=True)


def _isolated_env() -> dict[str, str]:
    """Return an env dict isolated from the user's real cache/env (no cache)."""
    env = {k: v for k, v in os.environ.items() if k != "MMCIF_DICT_PATH"}
    env["XDG_CONFIG_HOME"] = "/nonexistent-xdg-dir-for-smoke-test"
    env["HOME"] = "/nonexistent-home-for-smoke-test"
    return env


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the binary with cache/env isolation but without --dict."""
    return subprocess.run(
        [str(BINARY), *args],
        capture_output=True,
        text=True,
        env=_isolated_env(),
    )


def _run_with_dict(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the binary with --dict pointing at the compiled fixture."""
    assert _compiled_mdict is not None, "fixture not initialised"
    return subprocess.run(
        [str(BINARY), "--dict", str(_compiled_mdict), *args],
        capture_output=True,
        text=True,
        env=_isolated_env(),
    )


@pytest.fixture(scope="module", autouse=True)
def _build_and_compile(tmp_path_factory: pytest.TempPathFactory) -> None:
    """Build the binary and compile minimal.dic to .mdict (once per module)."""
    global _compiled_mdict  # noqa: PLW0603
    _ensure_binary()
    mdict_path = tmp_path_factory.mktemp("smoke").joinpath("minimal.mdict")
    r = subprocess.run(
        [str(BINARY), "compile", str(FIXTURE_DIC), "-o", str(mdict_path)],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, f"compile failed: {r.stderr}"
    _compiled_mdict = mdict_path


# ── Tests that need the fixture dictionary ───────────────────────────


def test_category_lookup() -> None:
    r = _run_with_dict("category", "test_category")
    assert r.returncode == 0, r.stderr
    assert "test_category" in r.stdout
    assert "id" in r.stdout


def test_item_lookup() -> None:
    r = _run_with_dict("item", "_test_category.id")
    assert r.returncode == 0, r.stderr
    assert "id" in r.stdout
    assert "test_category" in r.stdout


def test_show_auto_detects_category() -> None:
    r = _run_with_dict("show", "_test_category")
    assert r.returncode == 0, r.stderr
    assert "Category: test_category" in r.stdout


def test_show_auto_detects_item() -> None:
    r = _run_with_dict("show", "_test_category.id")
    assert r.returncode == 0, r.stderr
    assert "Item: _test_category.id" in r.stdout


def test_category_list_nonempty() -> None:
    r = _run_with_dict("category")
    assert r.returncode == 0, r.stderr
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    assert len(lines) > 0, f"got {len(lines)} categories"


def test_json_output_parses() -> None:
    r = _run_with_dict("--json", "category", "test_category")
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert data["id"] == "test_category"
    assert isinstance(data.get("items"), list)
    assert len(data["items"]) > 0


# ── Tests that do NOT need a dictionary ──────────────────────────────


def test_no_dict_error_message() -> None:
    """Without --dict and with isolated cache, the CLI should fail clearly."""
    r = _run("category", "test_category")
    assert r.returncode != 0
    assert "not found" in r.stderr
    assert "mmcif-dict fetch" in r.stderr


def test_unknown_name_reports_error() -> None:
    # --name ihm has no cache → should exit 1
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


def test_name_flag_rejected_with_compile() -> None:
    r = _run("--name", "foo", "compile", "/tmp/in.dic", "-o", "/tmp/out.mdict")
    assert r.returncode != 0
    assert "--name" in r.stderr
    assert "compile" in r.stderr


def test_mmcif_dict_path_overrides_name() -> None:
    # MMCIF_DICT_PATH pointing at nonexistent path should error out loudly.
    env = {k: v for k, v in os.environ.items()}
    env["MMCIF_DICT_PATH"] = "/nonexistent-dict-for-smoke-test.mdict"
    env["XDG_CONFIG_HOME"] = "/nonexistent-xdg-dir-for-smoke-test"
    env["HOME"] = "/nonexistent-home-for-smoke-test"
    r = subprocess.run(
        [str(BINARY), "category", "atom_site"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert r.returncode != 0
    # The path should appear in the error; confirms no silent fallback.
    assert "nonexistent-dict-for-smoke-test" in r.stderr


def test_empty_name_flag_rejected() -> None:
    r = _run("--name=", "category", "atom_site")
    assert r.returncode != 0
    assert "--name" in r.stderr


def test_invalid_name_rejected() -> None:
    # Space is not in the allowed [A-Za-z0-9_-] set
    r = _run("--name", "foo bar", "category", "atom_site")
    assert r.returncode != 0
    assert "invalid" in r.stderr.lower()


def _expected_version() -> str:
    """Parse the version string out of build.zig.zon without importing Zig."""
    text = PROJECT_ROOT.joinpath("build.zig.zon").read_text()
    for line in text.splitlines():
        stripped = line.strip()
        # Match `.version = "X"` exactly; reject siblings like `.version_foo`.
        if stripped.startswith(".version") and "=" in stripped and '"' in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key == ".version":
                return stripped.split('"', 2)[1]
    raise AssertionError("no .version line in build.zig.zon")


def test_version_long_flag() -> None:
    r = _run("--version")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == f"mmcif-dict {_expected_version()}"


def test_version_short_flag() -> None:
    r = _run("-V")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == f"mmcif-dict {_expected_version()}"


def test_help_mentions_version_flag() -> None:
    r = _run("--help")
    assert r.returncode == 0, r.stderr
    assert "--version" in r.stdout
    # Guard against someone quietly dropping the short form from usage text.
    assert "-V" in r.stdout


# ── Rich CLI output (tables, --no-table) ────────────────────────────


def test_relations_tsv_is_tab_separated() -> None:
    # Without a pty, stdout is a pipe -> tsv auto-selected.
    r = _run_with_dict("relations", "test_category")
    assert r.returncode == 0, r.stderr
    assert "│" not in r.stdout
    assert "─" not in r.stdout
    # Fixture has no relations, so we expect the "No relations found" path.
    # If the fixture ever gets relations, this assertion needs updating.
    assert "No relations found" in r.stdout or "\t" in r.stdout


def test_relations_no_table_flag_matches_pipe_default() -> None:
    r1 = _run_with_dict("relations", "test_category")
    r2 = _run_with_dict("--no-table", "relations", "test_category")
    assert r1.returncode == 0 and r2.returncode == 0
    assert r1.stdout == r2.stdout


def test_search_tsv_shape() -> None:
    r = _run_with_dict("search", "test")
    assert r.returncode == 0, r.stderr
    data_lines = [
        ln
        for ln in r.stdout.splitlines()
        if ln.strip() and not ln.startswith("No results")
    ]
    # Every data line (including header) has at least 2 tabs.
    for ln in data_lines:
        assert ln.count("\t") >= 2, f"expected 3 columns, got {ln!r}"


def test_category_items_tsv_one_per_line() -> None:
    r = _run_with_dict("category", "test_category")
    assert r.returncode == 0, r.stderr
    items_section = r.stdout.split("Items (", 1)[1]
    # Every non-empty line under Items should start with 2 spaces + _
    for ln in items_section.splitlines()[1:]:
        if not ln.strip():
            continue
        assert ln.startswith("  _"), f"unexpected item line: {ln!r}"


def test_no_table_flag_in_help() -> None:
    r = _run("--help")
    assert r.returncode == 0, r.stderr
    assert "--no-table" in r.stdout


def test_json_output_unchanged_by_table_flag() -> None:
    r1 = _run_with_dict("--json", "category", "test_category")
    r2 = _run_with_dict("--json", "--no-table", "category", "test_category")
    assert r1.returncode == 0 and r2.returncode == 0
    assert r1.stdout == r2.stdout


def test_relations_boxed_on_fake_tty() -> None:
    # Force a tty via pty to exercise the boxed branch.
    import pty

    assert _compiled_mdict is not None, "fixture not initialised"
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(
            str(BINARY),
            [str(BINARY), "--dict", str(_compiled_mdict), "relations", "test_category"],
            _isolated_env(),
        )
    # Parent: read until EOF.
    chunks: list[bytes] = []
    try:
        while True:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
    finally:
        os.close(fd)
        os.waitpid(pid, 0)
    out = b"".join(chunks).decode("utf-8", errors="replace")
    # Boxed mode emits Unicode borders.
    assert "│" in out or "No relations" in out, out[:200]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
