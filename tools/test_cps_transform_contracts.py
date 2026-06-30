"""Regression checks for the BL808 CPS transform macro."""

from __future__ import annotations

import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_cps_transform_accepts_openarray_and_default_params(tmp_path: Path):
    source = tmp_path / "cps_transform_contract.nim"
    source.write_text(
        """
import bl808/kernel/cps
import bl808/wasm_control

const DefaultFuel = 2'u32

proc withOpenArray(slot: uint32, args: openArray[int32],
                   fuel = DefaultFuel): CpsFuture[uint32] {.cps.} =
  await yieldNow()
  return args.len.uint32 + slot + fuel

proc withObjectResult(taskId: uint32,
                      fuel = DefaultFuel): CpsFuture[WasmControlTaskResult] {.cps.} =
  var last = getWasmProgramTask(taskId)
  var slices = 0'u32
  while last.status == wasmControlOk and slices < fuel:
    inc slices
    await yieldNow()
  return last

proc returnAwait(taskId: uint32): CpsFuture[WasmControlTaskResult] {.cps.} =
  return await withObjectResult(taskId)
""",
        encoding="utf-8",
    )
    subprocess.run(
        [
            "nim",
            "check",
            f"--path:{REPO_ROOT / 'src'}",
            "--define:bl808kernel",
            "--define:bl808m0",
            "--define:bl808WasmCompact",
            str(source),
        ],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
