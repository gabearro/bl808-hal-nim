"""Account for detached flush batches before a nested reset clears TX state."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_flush_lifetime import PLATFORM


def source() -> str:
    platform = PLATFORM.replace(
        "  TxControlAcView = object\n",
        "  TxControlAcView = object\n    packetCount: uint16\n    busyFlag: uint8\n",
    ).replace(
        "  TxControlEnvView = object\n",
        "  TxControlEnvView = object\n    seqCounter: uint16\n    resetInProgress: uint8\n",
    )
    platform += r'''
const WifiHwPollLimit = 4'u32
var
  txResetActive: bool
  txResetEpoch: uint32
  hardwareResets: int
proc volatileLoad(p: ptr uint32): uint32 =
  doAssert cast[uint](p) == 0x24A00010'u
  0xFFFF'u32
proc volatileStore(p: ptr uint32; value: uint32) =
  doAssert cast[uint](p) == 0x24A00020'u
proc noteHwWaitTimeout(address, mask: uint32) = doAssert false
proc hal_machw_disable_int() = doAssert false
proc txlResetting(): bool = txEnv.resetInProgress != 0
proc txl_hwdesc_reset() =
  doAssert txEnv.packetCounter == 0, "reset left detached packets unconfirmed"
  var batch = txActiveFlush
  while batch != nil:
    doAssert batch.confirmations.first == nil and batch.pending.first == nil
    doAssert batch.postponed.first == nil
    batch = batch.previous
  inc hardwareResets
proc txl_cfm_init() = confirmLists = default(typeof(confirmLists))
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert p == (addr txEnv) and value == 0 and size == 92
  txEnv = default(TxControlEnvView)
  p
proc ipcTxHwDescWordHalfword(ac: uint32): uint16 = ac.uint16
'''
    tx = (FW / "tx_layer.nim").read_text()
    functions = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    for name in ["txl_frame_cfm", "txlFrameConfirmPending", "txl_frame_evt",
                 "txl_frame_release", "txl_cfm_flush", "txl_cntrl_halt_ac",
                 "txlDetachAc", "txl_cntrl_flush_ac", "txl_cntrl_clear_ac",
                 "txlDrainRetiredPostponed", "txl_buffer_reinit", "txl_reset"]:
        functions += procedure(tx, name)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    return platform + debug + functions


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_drains_outer_batches(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var
  frames: array[8, HostTxDescView]
  hardware: array[8, HwDesc]
  heads: array[8, HeadThd]
  outputs: array[8, uint32]
  callbacks: array[8, int]
  older: TxFlushBatch
  fired, fromHost: bool
proc resetOnce() =
  if fired: return
  fired = true
  txl_reset()
  doAssert txEnv.packetCounter == 0 and frameEnv.postponedCount == 0
  doAssert txEnv.resetInProgress == 0 and not txResetActive
  # The resumed outer flush must not consume work from the new generation.
  co_list_push_back(addr txEnv.ac[1].pending, addr frames[7].link)
  txEnv.ac[1].current = addr hardware[7]
  buffers.backupQueues[1] = (cast[pointer](addr frames[7]), cast[pointer](addr frames[7]))
  txEnv.packetCounter = 1
proc completed(arg: pointer; status: uint32) {.cdecl.} =
  let index = cast[uint](arg).int - 1
  inc callbacks[index]
  if txResetActive:
    let epoch = txResetEpoch
    txl_reset()
    doAssert txResetEpoch == epoch
  if index == 0 and not fromHost: resetOnce()

for ac in 0'u8 .. 4:
  for host in [false, true]:
    for enabled in [false, true]:
      frames = default(typeof(frames))
      hardware = default(typeof(hardware))
      heads = default(typeof(heads))
      outputs = default(typeof(outputs))
      callbacks = default(typeof(callbacks))
      frameEnv = default(TxFrameEnvView)
      txEnv = default(TxControlEnvView)
      confirmLists = default(typeof(confirmLists))
      buffers = default(BufferEnv)
      older = TxFlushBatch(ac: 4, status: 0x12345678'u32)
      txActiveFlush = addr older
      txResetActive = false
      hardwareResets = 0
      fired = false
      fromHost = host
      interruptsEnabled = enabled
      active = 0x1F
      hostCompletions.setLen(0)
      indications.setLen(0)
      for i in 0 ..< frames.len:
        frames[i] = HostTxDescView(hwDesc: addr hardware[i], cfmDst: addr outputs[i], active: 1)
        hardware[i].head = addr heads[i]
        if i in [1, 2, 5, 6, 7]:
          frames[i].queueFirst = cast[pointer](1)
          frames[i].usedFlag = 1
        else:
          frames[i].callback = cast[pointer](completed)
          frames[i].callbackArg = cast[pointer](i + 1)
      co_list_push_back(addr frameEnv.usedList, addr frames[0].link)
      co_list_push_back(addr confirmLists[ac], addr frames[1].link)
      co_list_push_back(addr txEnv.ac[ac].pending, addr frames[2].link)
      co_list_push_back(addr txEnv.ac[ac].pending, addr frames[3].link)
      co_list_push_back(addr older.postponed, addr frames[4].link)
      co_list_push_back(addr older.confirmations, addr frames[5].link)
      co_list_push_back(addr older.pending, addr frames[6].link)
      frames[4].postponeFlag = 1
      frameEnv.postponedCount = 1
      txEnv.packetCounter = 6
      hostHook = proc(p: pointer) =
        if fromHost and p == cast[pointer](addr frames[1]): resetOnce()
      doAssert txl_cntrl_clear_ac(ac)
      hostHook = nil
      doAssert fired and hardwareResets == 1 and interruptsEnabled == enabled
      doAssert txActiveFlush == addr older
      doAssert older.confirmations.first == nil and older.pending.first == nil
      doAssert older.postponed.first == nil and frameEnv.postponedCount == 0
      doAssert txEnv.packetCounter == 1 and frames[4].postponeFlag == 0
      doAssert callbacks == [1, 0, 0, 1, 1, 0, 0, 0]
      doAssert listCount(frameEnv.freeList) == 3
      doAssert hostCompletions.len == 4
      for i in [1, 2, 5, 6]:
        doAssert cast[pointer](addr frames[i]) in hostCompletions
        doAssert outputs[i] == 0x40000001'u32 and frames[i].active == 0
      for i in 0 .. 4:
        doAssert confirmLists[i].first == nil
        if i == 1:
          doAssert txEnv.ac[i].pending.first == addr frames[7].link
          doAssert txEnv.ac[i].pending.last == addr frames[7].link
          doAssert txEnv.ac[i].current == addr hardware[7]
          doAssert buffers.backupQueues[i].first == addr frames[7]
          doAssert buffers.backupQueues[i].last == addr frames[7]
        else:
          doAssert txEnv.ac[i].pending.first == nil
          doAssert buffers.backupQueues[i].first == nil
      doAssert outputs[7] == 0 and frames[7].active == 1
      txActiveFlush = nil
''')
