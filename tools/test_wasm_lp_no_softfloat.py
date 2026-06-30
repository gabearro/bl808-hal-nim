"""Regression checks for compact/no-FP WebAssembly runtime build profiles."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOFT_FLOAT_SYMBOL = re.compile(
    r"("
    r"__(add|sub|mul|div|eq|ne|lt|le|gt|ge|unord)sf3|"
    r"__(fix|float|extend|trunc|floatsi|floatunsi)[a-z0-9_]*|"
    r"\b(fabs|fabsf|copysign|copysignf|floor|floorf|ceil|ceilf|"
    r"trunc|truncf|round|roundf|sqrt|sqrtf)\b"
    r")"
)


def require_nm() -> None:
    if shutil.which("riscv64-unknown-elf-nm") is None:
        pytest.skip("riscv64-unknown-elf-nm is not installed")


def run_make(target: str, source: str, build_dir: str, nim_flags: str | None = None) -> Path:
    cmd = ["make", target, f"FILE={source}", f"BUILD_DIR={build_dir}"]
    if nim_flags is not None:
        cmd.append(f"NIM_FLAGS={nim_flags}")
    subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return REPO_ROOT / build_dir


def undefined_symbols(objects: list[Path]) -> str:
    assert objects, "Nim cache did not contain object files"
    nm = subprocess.run(
        ["riscv64-unknown-elf-nm", "-u", *map(str, objects)],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return nm.stdout


def assert_no_soft_float(objects: list[Path]) -> None:
    symbols = undefined_symbols(objects)
    matches = sorted({match.group(0) for match in SOFT_FLOAT_SYMBOL.finditer(symbols)})
    assert matches == [], symbols


def test_lp_wasm_smoke_does_not_pull_soft_float_helpers():
    require_nm()
    build_dir = run_make("lp", "examples/lp_wasm_smoke_test.nim", "build/test_wasm_lp_no_softfloat")
    assert_no_soft_float(sorted((build_dir / "nimcache_lp").glob("*.o")))


def test_enclave_wasm_compact_smoke_does_not_pull_full_or_soft_float_runtime():
    require_nm()
    build_dir = run_make(
        "m0",
        "examples/m0_enclave_wasm_smoke_test.nim",
        "build/test_wasm_enclave_compact",
        "-d:bl808kernel -d:bl808enclave -d:bl808WasmCompact",
    )
    objects = sorted((build_dir / "nimcache_m0").glob("*.o"))
    wasm_objects = [path for path in objects if "@pcps@swasm" in path.name]
    assert_no_soft_float(wasm_objects)

    object_names = {path.name for path in objects}
    assert "@pcps@swasm@sruntime_int.nim.c.o" in object_names
    assert "@pcps@swasm@sruntime.nim.c.o" not in object_names


def test_enclave_wasm_full_smoke_uses_wram_profile_and_full_runtime():
    require_nm()
    build_dir = run_make(
        "m0",
        "examples/m0_enclave_wasm_smoke_test.nim",
        "build/test_wasm_enclave_full",
        "-d:bl808kernel -d:bl808enclave -d:bl808EnclaveWram",
    )
    objects = sorted((build_dir / "nimcache_m0").glob("*.o"))
    object_names = {path.name for path in objects}
    assert "@pcps@swasm@sruntime.nim.c.o" in object_names
    assert "@pcps@swasm@sruntime_int.nim.c.o" not in object_names

    nm = subprocess.run(
        ["riscv64-unknown-elf-nm", "-n", str(build_dir / "m0_firmware.elf")],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert "62030000 B __secure_ram_start" in nm.stdout
    assert "62030000 B __shared_buf_end" in nm.stdout
