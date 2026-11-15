"""Keep an internal allocation private across logging and power callouts."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = ALLOCATION_PLATFORM
for name in ["nimFwTrace2U32", "tpc_get_vif_tx_power_vs_rate"]:
    PLATFORM = PLATFORM.replace(procedure(PLATFORM, name), "")
PLATFORM += r"""
proc observe(point: string)
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-NIMFW] frame_get ": observe("get")
  elif s == "[WIFI-NIMFW] frame_hdr ": observe("header")
proc tpc_get_vif_tx_power_vs_rate(rate: uint32): int32 =
  observe("power")
  -17
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""

CHECKS = r"""
var
  stage: string
  fired: bool
  change, callsAfterLoss: int
  replacement: ptr HostTxDescView
  expectedDesc: HostTxDescView
  expectedHw: HwDesc
  expectedLink: LinkDesc

proc observe(point: string) =
  if stage.len == 0: return
  doAssert not interruptsEnabled, "allocator escaped its IRQ scope"
  if fired and change != 0:
    inc callsAfterLoss
    return
  if point != stage: return
  fired = true
  if change == 0: return
  stage = ""
  let frame = txlFrameDescAt(3)
  txl_frame_release(frame, false)
  if change == 2:
    replacement = hostTxDescAt(txl_frame_get(26))
    doAssert replacement == frame
    replacement.pendingMacTime = 0xA1B2C3D4'u32
    replacement.callback = cast[pointer](0x1234)
    replacement.callbackArg = cast[pointer](0x4567)
    for value in links[3].macHeader.mitems: value = 0xB5
    hardware[3].payloadStart = 0x76543210
    hardware[3].controlFlags = 0x1BCD
  expectedDesc = frame[]
  expectedHw = hardware[3]
  expectedLink = links[3]
  stage = point

for irq in [false, true]:
  for length in [1'u32, 24, 512]:
    for point in ["get", "header", "power"]:
      for action in 0 .. 2:
        stage = ""
        initPool()
        for i in 0 .. 2: discard txl_frame_get(24)
        interruptsEnabled = irq
        stage = point
        change = action
        fired = false
        callsAfterLoss = 0
        replacement = nil
        let frame = txl_frame_get(length)
        stage = ""
        doAssert fired and interruptsEnabled == irq
        if action == 0:
          doAssert frame == cast[pointer](txlFrameDescAt(3))
          doAssert hardware[3].frameLen == length + 4
          doAssert frameEnv.freeList.first == nil
        else:
          doAssert frame == nil, "allocator returned an ended or replacement lease"
          doAssert txlFrameDescAt(3)[] == expectedDesc
          doAssert hardware[3] == expectedHw and links[3] == expectedLink,
            "old allocator wrote after its lease ended"
          doAssert callsAfterLoss == 0, "old allocation made another callout after cancellation"
          doAssert co_list_cnt(addr frameEnv.freeList) == (if action == 1: 1'u32 else: 0'u32)
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "get", "header", "power", "irq"])
def test_allocator_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_release",
    ])
    allocation = procedure(tx, "txl_frame_get")
    guard = "      if not txlFrameLeaseMatches(desc, generation):\n        return nil\n"
    if mutation == "get":
        assert allocation.count(guard) == 2
        allocation = allocation.replace(guard, "", 1)
    elif mutation == "header":
        first = allocation.index(guard)
        second = allocation.index(guard, first + len(guard))
        allocation = allocation[:second] + allocation[second:].replace(guard, "", 1)
    elif mutation == "power":
        allocation = allocation.replace("    if not txlFrameLeaseMatches(desc, generation):\n      return nil\n", "")
    elif mutation == "irq":
        allocation = allocation.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    functions += allocation
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "allocator_lifetime.nim"
    source.write_text(PLATFORM + debug + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
