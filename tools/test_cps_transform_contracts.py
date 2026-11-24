"""Regression checks for the BL808 CPS transform macro."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


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


@pytest.mark.parametrize("mode", ["checked", "firmware"])
@pytest.mark.parametrize("compound", [False, True], ids=["global", "compound"])
@pytest.mark.parametrize("runtime", ["host", "kernel"])
def test_cps_await_assignment_keeps_its_destination(
    tmp_path: Path, mode: str, compound: bool, runtime: str,
):
    source = tmp_path / "cps_await_assignment.nim"
    source.write_text(
        """
when defined(testBl808Kernel):
  import bl808/kernel/[runtime, transform]
else:
  import cps/[runtime, transform]

var published: uint32
var publishedWords: array[2, uint32]

proc publishLease(lease: CpsFuture[uint32]): CpsFuture[uint32] {.cps.} =
  published = 0
  published = await lease
  return published

let delayed = newCpsFuture[uint32]()
let manager = publishLease(delayed)
doAssert published == 0 and not manager.finished
delayed.complete(0x7201a8c0'u32)
doAssert manager.read() == 0x7201a8c0'u32
doAssert published == 0x7201a8c0'u32, "await shadowed the published lease"

when defined(testCpsCompoundDestinations):
  var selected, evaluations: int

  proc chooseWord(): int =
    inc evaluations
    selected

  proc assignTargets(value: CpsFuture[uint32]): CpsFuture[uint32] {.cps.} =
    var local = 2'u32
    local = await value
    publishedWords[1] = await value
    return local

  let immediate = newCpsFuture[uint32]()
  immediate.complete(17'u32)
  doAssert assignTargets(immediate).read() == 17 and publishedWords[1] == 17

  proc assignAfterAwait(value: CpsFuture[uint32]): CpsVoidFuture {.cps.} =
    publishedWords[chooseWord()] = await value

  let later = newCpsFuture[uint32]()
  let write = assignAfterAwait(later)
  doAssert evaluations == 0 and not write.finished
  selected = 1
  later.complete(19'u32)
  write.read()
  doAssert evaluations == 1 and publishedWords == [0'u32, 19]

proc preserveOnFailure(value: CpsFuture[uint32]): CpsFuture[uint32] {.cps.} =
  try:
    published = await value
  except ValueError:
    discard
  return published

let rejected = newCpsFuture[uint32]()
let recovered = preserveOnFailure(rejected)
rejected.fail(newException(ValueError, "no new lease"))
doAssert recovered.read() == 0x7201a8c0'u32 and published == 0x7201a8c0'u32
""",
        encoding="utf-8",
    )
    flags = ([] if mode == "checked" else ["--mm:arc", "--exceptions:goto", "-d:release",
                                           "--checks:off", "--assertions:on"])
    if compound:
        flags.append("-d:testCpsCompoundDestinations")
    if runtime == "kernel":
        flags.append("-d:testBl808Kernel")
    run = subprocess.run(
        ["nim", "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{REPO_ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", *flags, str(source)],
        cwd=REPO_ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
    )
    assert run.returncode == 0, run.stdout
