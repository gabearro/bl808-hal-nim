"""Keep a detached TX completion separate from a replacement descriptor."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_tx_session import PLATFORM as SESSION_PLATFORM


def platform_source() -> str:
    source = SESSION_PLATFORM.replace(
        "proc mm_bcn_transmitted(vifEntry: pointer) = discard\n", ""
    )
    if "  mmBcnGeneration: uint32\n" not in source:
        source += "\nvar mmBcnGeneration: uint32\n"
    source = source.replace(
        "  interruptsEnabled = true", "  onRestore: proc()\n  interruptsEnabled = true", 1
    )
    source = source.replace(procedure(source, "irqRestore"), r"""
proc irqRestore(previous: uint32) =
  interruptsEnabled = (previous and 8) != 0
  if interruptsEnabled and onRestore != nil: onRestore()
""")
    return source + r"""
const VIF_TYPE_AP = 2'u8
type
  Vif = object
    vifIdx, vifType: uint8
  Env = object
    pendingCount: uint32
    templatePtr: pointer
    deferredChange: uint8
    timQueue: CoList
var
  vifs: array[2, Vif]
  beaconFrames: array[2, HostTxDescView]
  beaconHardware: array[2, HwDesc]
  beaconLinks: array[2, LinkDesc]
  env: Env
  mmBcnStopping: bool
  oldCalls, newCalls, timCalls, updates: int
  timHook: proc()
proc txlFrameCallbackCurrent(resetEpoch: uint32 = txResetEpoch): bool
proc bcnEnvView(): ptr Env = addr env
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc assert_err(condition, file: cstring; line: int) = doAssert false
proc keMsgPayload(p: ptr CoListHdr): pointer = p
type KeMsgHdr = CoListHdr
proc mm_tim_update_proceed(p: pointer) =
  inc timCalls
  if timHook != nil: timHook()
proc mmBcnApplyUpdate(p: pointer; irq: uint32): bool =
  inc updates
  true
proc oldCallback(p: pointer; status: uint32) {.cdecl.} =
  doAssert status == 0x80800000'u32
  inc oldCalls
proc newCallback(p: pointer; status: uint32) {.cdecl.} = inc newCalls
"""


CHECKS = r"""
proc resetOwner() =
  onRestore = nil
  interruptsEnabled = true
  setup()
  oldCalls = 0
  newCalls = 0
  timCalls = 0
  updates = 0
  mmBcnGeneration = 10
  mmBcnStopping = false
  env = default(Env)
  beaconFrames = default(typeof(beaconFrames))
  beaconHardware = default(typeof(beaconHardware))
  beaconLinks = default(typeof(beaconLinks))
  timHook = nil
  for i in 0 .. 1:
    vifs[i] = Vif(vifIdx: i.uint8, vifType: VIF_TYPE_AP)
    let frame = addr beaconFrames[i]
    frame.vifIdx = i.uint8
    frame.staInfoIdx = 255
    frame.usedFlag = 1
    frame.callback = cast[pointer](mm_bcn_transmitted)
    frame.callbackArg = addr vifs[i]
    frame.hwDesc = addr beaconHardware[i]
    frame.bufDesc = addr beaconLinks[i]
    beaconHardware[i].confirmStatus = 0x80800000'u32

# The first IRQ restore after the node is detached can reset and reuse it.
# Completion accounting must already belong to the old node at that point.
for beacon in [false, true]:
  for vif in 0'u8 .. 1:
    for retireVif in [false, true]:
      resetOwner()
      var held: array[4, ptr HostTxDescView]
      for i in 0 .. 3:
        held[i] = hostTxDescAt(txl_frame_get(24))
        held[i].vifIdx = vif
        held[i].staInfoIdx = 255
      let frame = if beacon: addr beaconFrames[vif] else: held[0]
      if not beacon:
        frame.callback = cast[pointer](oldCallback)
        frame.callbackArg = frame
        hostTxHwDescAt(frame.hwDesc).confirmStatus = 0x80800000'u32
      env.pendingCount = 1
      txEnv.packetCounter = 1
      co_list_push_back(addr frameEnv.usedList, addr frame.link)
      var fired = false
      var snapshot: HostTxDescView
      var hwSnapshot: HwDesc
      onRestore = proc() =
        if fired or frameEnv.usedList.first != nil: return
        fired = true
        onRestore = nil
        if retireVif: inc rxVifEpochs[vif]
        # A reset retires old accounting before starting the new submission.
        txEnv.packetCounter = 0
        if beacon:
          inc mmBcnGeneration
          frame[] = beaconFrames[vif]
          frame.retryFlag = 1
          env.pendingCount = 1
        else:
          txl_frame_release(frame, false)
          let replacement = hostTxDescAt(txl_frame_get(24))
          doAssert replacement == frame
          replacement.vifIdx = vif
          replacement.staInfoIdx = 255
          replacement.callback = cast[pointer](newCallback)
          replacement.callbackArg = replacement
        hostTxHwDescAt(frame.hwDesc).confirmStatus = 0x12345678
        inc txEnv.packetCounter
        snapshot = frame[]
        hwSnapshot = hostTxHwDescAt(frame.hwDesc)[]
      txl_frame_evt()
      onRestore = nil
      doAssert fired
      doAssert frame[] == snapshot, "old completion changed the replacement descriptor"
      doAssert hostTxHwDescAt(frame.hwDesc)[] == hwSnapshot
      doAssert txEnv.packetCounter == 1, "old completion consumed new accounting"
      doAssert env.pendingCount == 1, "old beacon callback consumed new accounting"
      doAssert newCalls == 0, "old completion invoked the replacement callback"
      doAssert oldCalls == (if beacon: 0 else: 1)
      doAssert frameEnv.freeList.first == nil

# Ordinary completions retain incoming IRQ state and drain deferred work.
for enabled in [false, true]:
  for vif in 0'u8 .. 1:
    resetOwner()
    let frame = addr beaconFrames[vif]
    var timNode: CoListHdr
    co_list_push_back(addr env.timQueue, addr timNode)
    env.pendingCount = 1
    env.deferredChange = 1
    env.templatePtr = cast[pointer](1)
    txEnv.packetCounter = 1
    co_list_push_back(addr frameEnv.usedList, addr frame.link)
    interruptsEnabled = enabled
    txl_frame_evt()
    doAssert interruptsEnabled == enabled
    doAssert env.pendingCount == 0 and txEnv.packetCounter == 0
    doAssert timCalls == 1 and updates == 1
    doAssert frameEnv.freeList.first == addr txlFrameDescAt(0).link

# A deferred TIM callback can itself replace the beacon. The outer completion
# must not clear flags on that new descriptor when the callback returns.
for enabled in [false, true]:
  for vif in 0'u8 .. 1:
    resetOwner()
    let frame = addr beaconFrames[vif]
    var timNode: CoListHdr
    co_list_push_back(addr env.timQueue, addr timNode)
    env.pendingCount = 1
    txEnv.packetCounter = 1
    co_list_push_back(addr frameEnv.usedList, addr frame.link)
    timHook = proc() =
      inc mmBcnGeneration
      frame.retryFlag = 1
      env.pendingCount = 1
      inc txEnv.packetCounter
    interruptsEnabled = enabled
    txl_frame_evt()
    doAssert interruptsEnabled == enabled
    doAssert timCalls == 1 and frame.retryFlag == 1
    doAssert env.pendingCount == 1 and txEnv.packetCounter == 1
    doAssert frameEnv.usedList.first == nil
    doAssert txActiveFrameCallback == nil
"""


def source(mutation: str | None) -> str:
    tx = (FW / "tx_layer.nim").read_text()
    mac = (FW / "kernel_mac_channel.nim").read_text()
    functions = procedure(mac, "mmBcnOwnerCurrent") + procedure(mac, "mm_bcn_transmitted")
    functions += "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlFrameConfirmPending", "txl_frame_evt",
    ])
    if mutation == "beacon_callback":
        guard = "  if not txlFrameCallbackCurrent(): return\n"
        assert functions.count(guard) == 1
        functions = functions.replace(guard, "")
    elif mutation == "beacon_lease":
        old = "  if index == InvalidFrameDescIndex:\n    return mmBcnGeneration == generation\n"
        assert functions.count(old) == 1
        functions = functions.replace(old, "  if index == InvalidFrameDescIndex:\n    return true\n")
    elif mutation == "early_restore":
        old = "    let node = co_list_pop_front(addr frameEnv.usedList)\n"
        assert functions.count(old) == 1
        functions = functions.replace(old, old + "    irqRestore(saved)\n")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    return platform_source() + debug + functions + CHECKS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "beacon_callback", "beacon_lease", "early_restore"])
def test_tx_completion_owner(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "completion_owner.nim"
    path.write_text(source(mutation))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release":
        command += ["-d:release"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
                f"-o:{tmp_path / 'test'}", str(path)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
