#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest"]
# ///
"""E2E: compile a tiny .dic and verify the resulting .mdict has the
expected header bytes."""

import struct
import subprocess
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BINARY = PROJECT_ROOT.joinpath("zig-out", "bin", "mmcif-dict")
FIXTURE = PROJECT_ROOT.joinpath("testdata", "tiny.dic")


def _ensure_binary():
    if not BINARY.exists():
        subprocess.run(["zig", "build"], cwd=PROJECT_ROOT, check=True)


def test_compile_produces_valid_mdict(tmp_path):
    _ensure_binary()
    out = tmp_path.joinpath("tiny.mdict")
    result = subprocess.run(
        [str(BINARY), "compile", str(FIXTURE), "-o", str(out)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert out.exists()

    data = out.read_bytes()
    assert len(data) >= 128
    # magic "MDICT\0\0\0"
    assert data[:8] == b"MDICT\x00\x00\x00"
    # version u32 LE
    assert struct.unpack("<I", data[8:12])[0] == 1
    # endian_mark u32 LE
    assert struct.unpack("<I", data[12:16])[0] == 0x04030201


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
