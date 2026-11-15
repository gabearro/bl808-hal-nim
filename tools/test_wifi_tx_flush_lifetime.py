"""Run real AC flush and confirmation paths across reentrant submissions."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_completion import PLATFORM as COMPLETION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = COMPLETION_PLATFORM.replace(
    "  TxFrameEnvView = object",
    """  TxControlAcView = object
    current: pointer
    pending: CoList
  TxControlEnvView = object
    ac: array[5, TxControlAcView]
    packetCounter: uint32
  BufferEnv = object
    backupQueues: array[5, tuple[first, last: pointer]]
  TxFrameEnvView = object""",
).replace("tuple[packetCounter: uint32]", "TxControlEnvView").replace(
    "var\n  frameEnv:",
    """var
  txRecoveryPostponed: CoList
  txlAcPending: array[5, uint32]
  txlAcBusy: array[5, bool]
  buffers: BufferEnv
  active: uint32
  hostHook: proc(p: pointer)
  frameEnv:""",
).replace(
    "  hostCompletions.add(p)",
    "  hostCompletions.add(p)\n  if hostHook != nil: hostHook(p)",
) + r"""
const
  NUM_TX_QUEUES = 5
  MACHW_INTC_BASE = 0x24B08000'u
proc txControlAc(ac: uint32): ptr TxControlAcView = addr txEnv.ac[ac]
proc txlBufferEnvView(): ptr BufferEnv = addr buffers
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc regRead(address: uint): uint32 =
  case address
  of 0x24B08188'u: 0
  of 0x24B0808C'u: active
  else:
    doAssert false, "unexpected register read"
    0
proc regWrite(address: uint; value: uint32) =
  doAssert not interruptsEnabled
  case address
  of 0x24B0808C'u: active = value
  of 0x24B08180'u, 0x24B08184'u, 0x24B08088'u: discard
  else: doAssert false, "unexpected register write"
"""

CHECKS = r"""
var
  desc: array[4, HostTxDescView]
  hw: array[4, HwDesc]
  head: array[4, HeadThd]
  output: array[4, uint32]
  selectedAc: uint8
  submitFromHost: bool
  submissions, internalCallbacks: int

proc submitNew() =
  inc submissions
  doAssert submissions == 1
  doAssert not interruptsEnabled
  let ac = selectedAc
  doAssert confirmLists[ac].first == nil
  doAssert txEnv.ac[ac].pending.first == nil
  doAssert txEnv.ac[ac].current == nil
  doAssert buffers.backupQueues[ac].first == nil
  doAssert buffers.backupQueues[ac].last == nil
  doAssert not txlAcBusy[ac] and txlAcPending[ac] == 0
  doAssert (active and (1'u32 shl ac)) == 0
  co_list_push_back(addr confirmLists[ac], addr desc[2].link)
  co_list_push_back(addr txEnv.ac[ac].pending, addr desc[3].link)
  txEnv.ac[ac].current = addr desc[3]
  buffers.backupQueues[ac] = (cast[pointer](addr desc[3]), cast[pointer](addr desc[3]))
  txlAcPending[ac] = 1
  txlAcBusy[ac] = true
  txEnv.packetCounter += 2
  active = active or (1'u32 shl ac)

proc onInternal(arg: pointer; status: uint32) {.cdecl.} =
  doAssert arg == addr desc[1]
  inc internalCallbacks
  doAssert internalCallbacks == 1
  if not submitFromHost: submitNew()

for ac in 0'u8 .. 4:
  for hostFirst in [false, true]:
    selectedAc = ac
    submitFromHost = hostFirst
    submissions = 0
    internalCallbacks = 0
    desc = default(typeof(desc))
    hw = default(typeof(hw))
    head = default(typeof(head))
    output = default(typeof(output))
    frameEnv = default(TxFrameEnvView)
    txEnv = default(TxControlEnvView)
    confirmLists = default(typeof(confirmLists))
    buffers = default(BufferEnv)
    hostCompletions.setLen(0)
    indications.setLen(0)
    interruptsEnabled = true
    active = 0x1F
    for i in 0 ..< desc.len:
      desc[i].hwDesc = addr hw[i]
      desc[i].cfmDst = addr output[i]
      hw[i].head = addr head[i]
      head[i].flags = 0
      if (i and 1) == 0:
        desc[i].queueFirst = cast[pointer](1)
        desc[i].usedFlag = 1
    desc[1].callback = cast[pointer](onInternal)
    desc[1].callbackArg = addr desc[1]
    hostHook = proc(p: pointer) =
      if p == cast[pointer](addr desc[0]) and submitFromHost: submitNew()
    txEnv.packetCounter = 2
    co_list_push_back(addr confirmLists[ac], addr desc[0].link)
    co_list_push_back(addr txEnv.ac[ac].pending, addr desc[1].link)
    txEnv.ac[ac].current = addr desc[1]
    buffers.backupQueues[ac] = (cast[pointer](addr desc[1]), cast[pointer](addr desc[1]))
    txlAcPending[ac] = 1
    txlAcBusy[ac] = true

    doAssert txl_cntrl_clear_ac(ac)
    doAssert interruptsEnabled and submissions == 1 and internalCallbacks == 1
    doAssert hostCompletions == @[cast[pointer](addr desc[0])]
    doAssert frameEnv.freeList.first == addr desc[1].link
    doAssert frameEnv.freeList.last == addr desc[1].link
    doAssert txEnv.packetCounter == 2
    doAssert confirmLists[ac].first == addr desc[2].link
    doAssert confirmLists[ac].last == addr desc[2].link
    doAssert txEnv.ac[ac].pending.first == addr desc[3].link
    doAssert txEnv.ac[ac].pending.last == addr desc[3].link
    doAssert txEnv.ac[ac].current == addr desc[3]
    doAssert buffers.backupQueues[ac].first == addr desc[3]
    doAssert buffers.backupQueues[ac].last == addr desc[3]
    doAssert txlAcBusy[ac] and txlAcPending[ac] == 1
    doAssert active == 0x1F
    doAssert output[0] == 0x40000001'u32 and output[2] == 0

    # The newly submitted frames complete once, on their own later flush.
    doAssert txl_cntrl_clear_ac(ac)
    doAssert txEnv.packetCounter == 0 and internalCallbacks == 1
    doAssert hostCompletions == @[cast[pointer](addr desc[0]), cast[pointer](addr desc[2])]
    doAssert listCount(frameEnv.freeList) == 2
    doAssert confirmLists[ac].first == nil and txEnv.ac[ac].pending.first == nil
    doAssert txEnv.ac[ac].current == nil
    doAssert buffers.backupQueues[ac].first == nil and buffers.backupQueues[ac].last == nil
    doAssert output[2] == 0x40000001'u32
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_flush_callback_lifetime(tmp_path: Path, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    upper = (FW / "tx_upper.nim").read_text()
    bodies = procedure(upper, "txu_cntrl_cfm")
    for name in ["txl_frame_cfm", "txlFrameConfirmPending", "txl_frame_evt",
                 "txl_cfm_flush", "txl_cntrl_halt_ac", "txlDetachAc", "txl_cntrl_flush_ac",
                 "txl_cntrl_clear_ac"]:
        bodies += procedure(tx, name)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    source = tmp_path / "tx_flush_lifetime.nim"
    platform = PLATFORM.replace("    packetCounter: uint32\n",
                                "    packetCounter: uint32\n    resetInProgress: uint8\n")
    platform += """
const WifiHwPollLimit = 4'u32
proc txlResetting(): bool = txEnv.resetInProgress != 0
proc noteHwWaitTimeout(address, mask: uint32) = doAssert false
proc hal_machw_disable_int() = doAssert false
"""
    source.write_text(platform + debug + bodies + CHECKS)
    modes = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *modes[mode], str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
