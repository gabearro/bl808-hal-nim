"""Preserve a frame's completion before IRQ-visible pool publication."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = ALLOCATION_PLATFORM.replace("  interruptsEnabled = true", """  watchFree = false
  restoreHook: proc()
  interruptsEnabled = true""", 1)
    old = procedure(source, "irqRestore")
    source = source.replace(old, r"""
proc irqRestore(previous: uint32) =
  interruptsEnabled = (previous and 8) != 0
  if interruptsEnabled and restoreHook != nil:
    let hook = restoreHook
    restoreHook = nil
    hook()
""")
    old = procedure(source, "co_list_push_back")
    source = source.replace(old, old.replace("  var present = list.first", """  if watchFree and list == addr frameEnv.freeList:
    doAssert not interruptsEnabled, "free publication was interruptible"
  var present = list.first"""))
    return source + r"""
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""


CHECKS = r"""
var
  oldCalls, newCalls, restores: int
  oldArg, newArg: int
  incoming: bool
  replacement: ptr HostTxDescView
  replacementSnapshot: HostTxDescView

proc oldCallback(argument: pointer; status: uint32) {.cdecl.} =
  doAssert argument == (addr oldArg) and status == 0
  doAssert interruptsEnabled == incoming
  inc oldCalls

proc newCallback(argument: pointer; status: uint32) {.cdecl.} =
  doAssert argument == addr newArg
  inc newCalls

for callbacks in [false, true]:
  for irq in [false, true]:
    for reuse in [false, true]:
      watchFree = false
      restoreHook = nil
      interruptsEnabled = true
      initPool()
      var held: array[4, ptr HostTxDescView]
      for i in 0 .. 3:
        held[i] = hostTxDescAt(txl_frame_get(24))
        doAssert held[i] != nil
        held[i].vifIdx = 0
        held[i].staInfoIdx = 0
      held[0].callback = cast[pointer](oldCallback)
      held[0].callbackArg = addr oldArg
      oldCalls = 0
      newCalls = 0
      restores = 0
      replacement = nil
      incoming = irq
      interruptsEnabled = irq
      watchFree = true
      restoreHook = proc() =
        inc restores
        doAssert frameEnv.freeList.first == addr held[0].link
        if reuse:
          replacement = hostTxDescAt(txl_frame_get(24))
          doAssert replacement == held[0]
          replacement.callback = cast[pointer](newCallback)
          replacement.callbackArg = addr newArg
          replacement.pendingMacTime = 0x12345678
          replacementSnapshot = replacement[]
      txl_frame_release(held[0], callbacks)
      restoreHook = nil
      doAssert interruptsEnabled == irq
      doAssert oldCalls == callbacks.int and newCalls == 0
      doAssert restores == irq.int
      if irq and reuse:
        doAssert replacement[] == replacementSnapshot
        doAssert txlFrameLeaseMatches(replacement, txlFrameLeaseToken(replacement))
        doAssert frameEnv.freeList.first == nil
      else:
        doAssert frameEnv.freeList.first == addr held[0].link
        doAssert frameEnv.freeList.last == addr held[0].link
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "unlocked", "live_callback"])
def test_frame_release_irq(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop", "txl_frame_get",
    ])
    body = procedure(tx, "txl_frame_release")
    if mutation == "unlocked":
        old = "    let saved = irqSave()\n    defer: irqRestore(saved)\n"
        assert old in body
        body = body.replace(old, "")
    elif mutation == "live_callback":
        old = "txlInvokeFrameCallback(completion.callback, completion.argument, 0,"
        assert old in body
        body = body.replace(old, "txlInvokeFrameCallback(hostTxDescAt(param).callback, hostTxDescAt(param).callbackArg, 0,")
    functions += body
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "release.nim"
    source.write_text(platform_source() + debug + functions + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *options[mode], str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
