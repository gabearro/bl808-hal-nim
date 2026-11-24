"""Exercise VIF retirement with real TX queue and completion procedures."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_station_tx_drain import PLATFORM as STATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = STATION_PLATFORM.replace(
    "proc txlVifIsRetiring(index: uint8): bool = false\n", ""
) + r"""
var
  txRetiringVifEpochs: array[MAX_VIFS, uint32]
  txRetiringVifMask: uint32
  haltMask: uint32
proc txlVifIsRetiring(vifIdx: uint8): bool
proc txl_retire_vif(vifIdx: uint8; selected: uint8)
proc rxInvalidateVif(vifIdx: uint8): bool
"""
PLATFORM = PLATFORM.replace(
    "of 0x24B08180'u, 0x24B08184'u, 0x24B08088'u: discard",
    """of 0x24B08180'u:
    const triggers = [0x10000'u32, 0x20000, 0x40000, 0x80000, 0x8000]
    for i, trigger in triggers:
      if value == trigger: haltMask = haltMask or (1'u32 shl i)
  of 0x24B08184'u, 0x24B08088'u: discard""",
)
# The MMIO double precedes the added declarations.
PLATFORM = PLATFORM.replace("  active: uint32\n", "  active, haltMask: uint32\n").replace(
    "  txRetiringVifMask: uint32\n  haltMask: uint32\n",
    "  txRetiringVifMask: uint32\n",
)

CHECKS = r"""
var
  frames: array[16, HostTxDescView]
  hardware: array[16, HwDesc]
  heads: array[16, HeadThd]
  outputs: array[16, uint32]
  wrappers: array[4, IpcHostTxWrapperView]
  seen: array[16, int]
  selectedVif, newAc: uint8
  mode, callbackCount: int
  firstCallback: bool

proc reset() =
  frames = default(typeof(frames))
  hardware = default(typeof(hardware))
  heads = default(typeof(heads))
  outputs = default(typeof(outputs))
  wrappers = default(typeof(wrappers))
  seen = default(typeof(seen))
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  frameEnv = default(TxFrameEnvView)
  txEnv = default(TxControlEnvView)
  confirmLists = default(typeof(confirmLists))
  buffers = default(BufferEnv)
  hostQueue = default(CoList)
  ipc.hostTxList = addr hostQueue
  txActiveFlush = nil
  rxVifEpochs = default(typeof(rxVifEpochs))
  txRetiringVifEpochs = default(typeof(txRetiringVifEpochs))
  txRetiringVifMask = 0
  txlAcPending = default(typeof(txlAcPending))
  txlAcBusy = default(typeof(txlAcBusy))
  active = 0x1F
  haltMask = 0
  callbackCount = 0
  fakeTransfers = 0
  firstCallback = true
  hostCompletions.setLen(0)
  indications.setLen(0)
  hostHook = nil
  interruptsEnabled = true
  for i in 0 ..< frames.len:
    frames[i].hwDesc = addr hardware[i]
    frames[i].cfmDst = addr outputs[i]
    frames[i].callbackArg = addr frames[i]
    frames[i].vifIdx = selectedVif
    frames[i].staInfoIdx = 255
    hardware[i].head = addr heads[i]
  for station in stations.mitems:
    station.valid = 1
    station.instNbr = selectedVif

proc completion(p: pointer; status: uint32) {.cdecl.}

proc observed(p: pointer) =
  doAssert not interruptsEnabled
  var index = -1
  for i in 0 ..< frames.len:
    if p == cast[pointer](addr frames[i]): index = i
  doAssert index >= 0
  inc seen[index]
  inc callbackCount
  doAssert seen[index] == 1, "duplicate completion"
  if not firstCallback: return
  firstCallback = false
  # No completion may run until all old hardware and postponed queues detach.
  doAssert haltMask == 0x1F
  for ac in 0 .. 4:
    doAssert txEnv.ac[ac].pending.first == nil and confirmLists[ac].first == nil
    doAssert txEnv.ac[ac].current == nil
    doAssert buffers.backupQueues[ac].first == nil
    doAssert not txlAcBusy[ac] and txlAcPending[ac] == 0
  doAssert stations[0].postponedList.first == nil
  doAssert stations[2].postponedList.first == nil
  doAssert stations[4].postponedList.first == addr frames[9].link
  doAssert txActiveFlush != nil
  doAssert wrappers[0].txDesc.vifIdx == 255 and wrappers[2].txDesc.vifIdx == 255
  doAssert wrappers[1].txDesc.vifIdx == (selectedVif xor 1)
  doAssert txlVifIsRetiring(selectedVif)
  doAssert not txlVifIsRetiring(selectedVif xor 1)
  # A new allocation in the invalidated session cannot enter a DMA chain.
  let count = txEnv.packetCounter
  doAssert txl_cntrl_push_int_force(addr frames[11], newAc) == 0
  doAssert txEnv.packetCounter == count and fakeTransfers == 0
  if mode == 1:
    # Nested VIF invalidation must find all outer detached batches, including
    # postponed descriptors, before this callback can reuse the session.
    doAssert rxInvalidateVif(selectedVif)
    for i in 0 .. 8:
      if i != index and i != 5: doAssert seen[i] == 1
    doAssert frameEnv.postponedCount == 1
    doAssert not txlVifIsRetiring(selectedVif)
    frames[12].callback = nil
    doAssert txl_cntrl_push_int_force(addr frames[12], newAc) == 1
    wrappers[3].txDesc.vifIdx = selectedVif
    wrappers[3].txDesc.staInfoIdx = 2
    co_list_push_back(addr hostQueue, addr wrappers[3].link)
  elif mode == 2:
    # Station deletion can also encounter postponed work detached by a VIF.
    stations[2].valid = 0
    var selected: uint8
    doAssert txlHaltStationQueues(2, selected)
    txl_retire_station(2, selected)
    doAssert seen[7] == 1 and seen[8] == 1
    doAssert frameEnv.postponedCount == 1

proc completion(p: pointer; status: uint32) {.cdecl.} = observed(p)

for vif in 0'u8 .. 1:
  for queue in 0'u8 .. 4:
    for nestedMode in 0 .. 2:
      selectedVif = vif
      newAc = queue
      mode = nestedMode
      reset()
      for i in 0 .. 8:
        frames[i].callback = cast[pointer](completion)
      for ac in 0 .. 4:
        let queue = if (ac and 1) == 0: addr txEnv.ac[ac].pending
                    else: addr confirmLists[ac]
        co_list_push_back(queue, addr frames[ac].link)
        # Deliberately not a software descriptor. Retirement must not cast it.
        txEnv.ac[ac].current = cast[pointer](1)
        txlAcBusy[ac] = true
        txlAcPending[ac] = 1
        buffers.backupQueues[ac] = (cast[pointer](1), cast[pointer](1))
      # Host collateral in an affected hardware chain is retired as a unit.
      frames[5].vifIdx = vif xor 1
      frames[5].usedFlag = 1
      frames[5].queueFirst = cast[pointer](1)
      co_list_push_back(addr txEnv.ac[3].pending, addr frames[5].link)
      co_list_push_back(addr frameEnv.usedList, addr frames[6].link)
      for i in [7, 8]:
        frames[i].staInfoIdx = 2
        frames[i].postponeFlag = 1
        co_list_push_back(addr stations[(i - 7) * 2].postponedList, addr frames[i].link)
      frames[9].vifIdx = vif xor 1
      frames[9].postponeFlag = 1
      co_list_push_back(addr stations[4].postponedList, addr frames[9].link)
      frameEnv.postponedCount = 3
      txEnv.packetCounter = 7
      for i in 0 .. 2:
        wrappers[i].active = (10 + i).uint32
        wrappers[i].txDesc.vifIdx = if i == 1: vif xor 1 else: vif
        wrappers[i].txDesc.staInfoIdx = 2
        co_list_push_back(addr hostQueue, addr wrappers[i].link)
      hostHook = observed

      doAssert rxInvalidateVif(vif)
      doAssert interruptsEnabled
      doAssert callbackCount == 9
      for i in 0 .. 8: doAssert seen[i] == 1
      doAssert seen[9] == 0
      doAssert txEnv.packetCounter == (mode == 1).uint32
      doAssert frameEnv.postponedCount == 1
      doAssert frames[7].postponeFlag == 0 and frames[8].postponeFlag == 0
      doAssert txActiveFlush == nil and txRetiringVifMask == 0
      doAssert txRetiringVifEpochs == default(typeof(txRetiringVifEpochs))
      doAssert rxVifEpochs[vif] == (if mode == 1: 2'u32 else: 1'u32)
      doAssert rxVifEpochs[vif xor 1] == 0
      for i in 0 .. 2: doAssert wrappers[i].active == (10 + i).uint32
      doAssert hostQueue.first == addr wrappers[0].link
      doAssert wrappers[0].link.next == addr wrappers[1].link
      doAssert wrappers[1].link.next == addr wrappers[2].link
      if mode == 1:
        doAssert fakeTransfers == 1
        doAssert txEnv.ac[newAc].pending.first == addr frames[12].link
        doAssert hostQueue.last == addr wrappers[3].link
        doAssert wrappers[3].txDesc.vifIdx == vif and wrappers[3].txDesc.staInfoIdx == 2
      else:
        doAssert fakeTransfers == 0
        doAssert hostQueue.last == addr wrappers[2].link
        for ac in 0 .. 4: doAssert txEnv.ac[ac].pending.first == nil

# A VIF without ownership of an AC must leave that chain and its THD untouched.
for vif in 0'u8 .. 1:
  for ac in 0'u8 .. 4:
    selectedVif = vif
    reset()
    frames[0].vifIdx = vif xor 1
    co_list_push_back(addr txEnv.ac[ac].pending, addr frames[0].link)
    txEnv.ac[ac].current = cast[pointer](1)
    buffers.backupQueues[ac] = (cast[pointer](2), cast[pointer](3))
    txEnv.packetCounter = 1
    doAssert rxInvalidateVif(vif)
    doAssert haltMask == 0 and txEnv.packetCounter == 1
    doAssert txEnv.ac[ac].pending.first == addr frames[0].link
    doAssert txEnv.ac[ac].current == cast[pointer](1)
    doAssert buffers.backupQueues[ac] == (cast[pointer](2), cast[pointer](3))

# Invalid VIF indexes have no effects, including preserving the incoming IRQ state.
for vif in 2 .. 255:
  for enabled in [false, true]:
    interruptsEnabled = enabled
    let epochs = rxVifEpochs
    doAssert not rxInvalidateVif(vif.uint8)
    doAssert rxVifEpochs == epochs and interruptsEnabled == enabled
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "no_retirement", "no_gate", "no_postponed_ancestor"])
def test_vif_tx_retirement(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    bodies = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    for name in [
        "txlStationAdmits", "txl_frame_release", "txl_frame_cfm",
        "txlFrameConfirmPending", "txl_frame_evt", "txl_cfm_flush",
        "txl_cntrl_halt_ac", "txlDetachAc", "txlQueueReferencesStation",
        "txlQueueReferencesVif", "txlHaltVifQueues", "txlHaltStationQueues",
        "txlDrainRetiredPostponed", "txlVifIsRetiring",
        "txl_retire_vif", "txl_cntrl_flush_ac", "txl_retire_station",
        "txl_cntrl_push_int_force",
    ]:
        bodies += procedure(tx, name)
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    if mutation == "no_retirement":
        old, new = "  txl_retire_vif(vifIdx, selected)\n", ""
    elif mutation == "no_gate":
        old = "  if txlVifIsRetiring(desc.vifIdx) or not txlFrameSessionCurrent(desc):"
        new = "  if not txlFrameSessionCurrent(desc):"
    elif mutation == "no_postponed_ancestor":
        old = ("    if txlQueueReferencesVif(addr batch.postponed, vifIdx):\n"
               "      txlDrainRetiredPostponed(addr batch.postponed)\n")
        new = ""
    if mutation is not None:
        assert bodies.count(old) == 1
        bodies = bodies.replace(old, new)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    source = tmp_path / "vif_tx.nim"
    source.write_text(PLATFORM + debug + bodies + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
