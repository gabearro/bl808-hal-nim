"""Run production TX halt, flush and reset ordering against MMIO doubles."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_ownership import DMA_INVALIDATION_STUBS

ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const
  NUM_TX_QUEUES = 5
  WifiHwPollLimit = 4'u32
  MACHW_INTC_BASE = 0x24B08000'u
  triggers = [0x10000'u32, 0x20000, 0x40000, 0x80000, 0x8000]
  shifts = [4, 8, 12, 16, 0]
type
  CoList = object
    first, last: pointer
  TxControlAcView = object
    current: pointer
    pending: CoList
    packetCount: uint16
    busyFlag: uint8
  TxControlEnvView = object
    ac: array[5, TxControlAcView]
    packetCounter: uint32
    seqCounter: uint16
    resetInProgress: uint8
  BufferEnv = object
    backupQueues: array[5, CoList]
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    confirmations, pending, postponed: CoList
var
  txActiveFlush: ptr TxFlushBatch
  txRecoveryPostponed: CoList
  txResetActive: bool
  txResetEpoch: uint32
  control: TxControlEnvView
  buffers: BufferEnv
  confirms: array[5, CoList]
  txlAcPending: array[5, uint32]
  txlAcBusy: array[5, bool]
  writes: seq[tuple[address: uint, value: uint32]]
  operations: seq[string]
  flushAcs: seq[uint8]
  flushLists: seq[pointer]
  flushHeads: seq[pointer]
  active = 0x1F'u32
  statusSamples: seq[uint32]
  statusIndex, assertions: int
  interrupts = true
  resetMode = false
  resetStatusReads: int
  resetSamples: seq[uint32]
  maxResetStatusReads: int
  waitTimeouts: seq[tuple[address, mask: uint32]]
  events: uint32
  onFlush: proc(ac: uint8)
proc txControlEnv(): ptr TxControlEnvView = addr control
proc txlResetting(): bool = control.resetInProgress != 0
proc txControlAc(ac: uint32): ptr TxControlAcView = addr control.ac[ac]
proc txCfmList(ac: uint32): ptr CoList = addr confirms[ac]
proc txlBufferEnvView(): ptr BufferEnv = addr buffers
proc assert_err(file, text: cstring; line: int) = inc assertions
proc regRead(address: uint): uint32 =
  case address
  of 0x24B08188'u:
    doAssert statusIndex < statusSamples.len, "halt did not use the queue status field"
    result = statusSamples[statusIndex]
    inc statusIndex
  of 0x24B0808C'u: result = active
  else: doAssert false, "unexpected register read"
proc regWrite(address: uint; value: uint32) =
  if address == 0x24B08184'u:
    for ac in 0 .. 4:
      if value == triggers[ac]:
        doAssert statusIndex > 0
        doAssert (statusSamples[statusIndex - 1] and (3'u32 shl shifts[ac])) == 0,
          "halt returned while DMA was active"
  writes.add((address, value))
  if address == 0x24B0808C'u: active = value
proc waitRegMaskClear(address: uint; mask: uint32): bool =
  for i in 0 ..< 4:
    if (regRead(address) and mask) == 0: return true
  false
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc txl_cfm_flush(ac: uint8; list: ptr CoList; status: uint32) =
  doAssert not interrupts
  doAssert status in [0x40000000'u32, 0x12345678'u32]
  if resetMode: doAssert control.resetInProgress == 1
  flushAcs.add(ac)
  flushLists.add(list)
  flushHeads.add(list.first)
  operations.add("flush")
  list[] = default(CoList)
  if onFlush != nil: onFlush(ac)
proc txlDrainRetiredPostponed(list: ptr CoList) =
  doAssert list.first == nil
proc volatileLoad(p: ptr uint32): uint32 =
  doAssert cast[uint](p) == 0x24A00010'u
  inc resetStatusReads
  if maxResetStatusReads != 0 and resetStatusReads > maxResetStatusReads:
    raise newException(ValueError, "TX idle wait exceeded its poll budget")
  if resetSamples.len != 0:
    return resetSamples[min(resetStatusReads - 1, resetSamples.high)]
  if resetStatusReads < 3: 0x1234'u32 else: 0xABCDFFFF'u32
proc noteHwWaitTimeout(address, mask: uint32) =
  doAssert not interrupts
  waitTimeouts.add((address, mask))
proc hal_machw_disable_int() = operations.add("disable-mac")
proc ke_evt_set(mask: uint32) =
  doAssert mask == 0x80000000'u32
  events = events or mask
proc volatileStore(p: ptr uint32; value: uint32) =
  doAssert cast[uint](p) == 0x24A00020'u
  writes.add((cast[uint](p), value))
proc txl_hwdesc_reset() =
  doAssert flushAcs.len == 10
  operations.add("hardware")
proc txl_cfm_init() =
  operations.add("confirm")
  confirms = default(typeof(confirms))
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert p == (addr control) and value == 0 and length == 92
  control = default(TxControlEnvView)
  operations.add("clear")
  p
proc ke_evt_clear(mask: uint32) =
  doAssert mask == 0x7C000
  events = events and not mask
proc ipcTxHwDescWordHalfword(ac: uint32): uint16 = (0x1234 + ac).uint16
"""

PLATFORM += DMA_INVALIDATION_STUBS

SETUP = r"""
proc setup() =
  control = default(TxControlEnvView)
  buffers = default(BufferEnv)
  confirms = default(typeof(confirms))
  for ac in 0 .. 4:
    control.ac[ac].current = cast[pointer](100 + ac)
    control.ac[ac].pending.first = cast[pointer](200 + ac)
    control.ac[ac].pending.last = cast[pointer](300 + ac)
    control.ac[ac].packetCount = 0xAA55
    control.ac[ac].busyFlag = 1
    buffers.backupQueues[ac].first = cast[pointer](400 + ac)
    buffers.backupQueues[ac].last = cast[pointer](500 + ac)
    confirms[ac].first = cast[pointer](600 + ac)
    confirms[ac].last = cast[pointer](700 + ac)
    txlAcPending[ac] = 8
    txlAcBusy[ac] = true
  control.packetCounter = 10
  control.seqCounter = 0xFFF
  writes.setLen(0)
  operations.setLen(0)
  flushAcs.setLen(0)
  flushLists.setLen(0)
  flushHeads.setLen(0)
  active = 0x1F
  statusIndex = 0
  assertions = 0
  interrupts = true
  resetMode = false
  resetStatusReads = 0
  resetSamples.setLen(0)
  maxResetStatusReads = 0
  waitTimeouts.setLen(0)
  onFlush = nil
  doAssert txActiveFlush == nil
  events = 0xFFFFFFFF'u32
"""

HALT = r"""
for ac in 0'u8 .. 4'u8:
  for queueState in 1'u32 .. 3'u32:
    setup()
    let fieldMask = 3'u32 shl shifts[ac]
    let unrelated = 0xFFFFFFFF'u32 and not fieldMask and not triggers[ac]
    statusSamples = @[(queueState shl shifts[ac]) or unrelated, unrelated]
    doAssert txl_cntrl_halt_ac(ac)
    doAssert statusIndex == 2
    doAssert writes == @[(0x24B08180'u, triggers[ac]), (0x24B08184'u, triggers[ac])]
  setup()
  # A busy unrelated queue must not keep this idle queue halted.
  statusSamples = @[0xFFFFFFFF'u32 and not (3'u32 shl shifts[ac])]
  doAssert txl_cntrl_halt_ac(ac)
  doAssert statusIndex == 1 and writes.len == 2
for invalid in [5'u8, 31, 255]:
  setup()
  doAssert not txl_cntrl_halt_ac(invalid)
  doAssert assertions == 1 and writes.len == 0 and statusIndex == 0
"""

FLUSH = r"""
for ac in 0'u8 .. 4'u8:
  for alreadyMasked in [false, true]:
    setup()
    let mask = 1'u32 shl ac
    if alreadyMasked: active = active and not mask
    let originalActive = active
    interrupts = false
    txl_cntrl_flush_ac(ac, 0x12345678)
    doAssert flushAcs == @[ac, ac]
    doAssert flushHeads == @[cast[pointer](600 + ac.int), cast[pointer](200 + ac.int)]
    doAssert control.ac[ac].current == nil, "flush retained a freed current descriptor"
    doAssert writes == @[(0x24B0808C'u, originalActive and not mask), (0x24B08088'u, mask)]
    doAssert not interrupts
    for other in 0 .. 4:
      if other != ac.int:
        doAssert control.ac[other].current == cast[pointer](100 + other)
        doAssert control.ac[other].pending.first == cast[pointer](200 + other)
        doAssert buffers.backupQueues[other].first == cast[pointer](400 + other),
          "flush detached another AC's backup queue"
        doAssert buffers.backupQueues[other].last == cast[pointer](500 + other)
    doAssert buffers.backupQueues[ac].first == nil and buffers.backupQueues[ac].last == nil,
      "flush retained backup links to released descriptors"
for invalid in [5'u8, 31, 255]:
  setup()
  txl_cntrl_flush_ac(invalid, 0x12345678)
  doAssert assertions == 1 and writes.len == 0 and flushAcs.len == 0
"""

RESET = r"""
setup()
interrupts = false
resetMode = true
txl_reset()
doAssert not interrupts and resetStatusReads == 3
doAssert events == (0xFFFFFFFF'u32 and not 0x7C000'u32)
doAssert flushAcs == @[0'u8, 0, 1, 1, 2, 2, 3, 3, 4, 4]
doAssert operations == @["flush", "flush", "flush", "flush", "flush", "flush",
  "flush", "flush", "flush", "flush", "hardware", "confirm", "clear"]
doAssert control.seqCounter == 0xFFF and control.resetInProgress == 0
doAssert control.packetCounter == 0
for ac in 0 .. 4:
  doAssert control.ac[ac].current == nil and control.ac[ac].pending.first == nil
  doAssert control.ac[ac].pending.last == nil and control.ac[ac].busyFlag == 0
  doAssert control.ac[ac].packetCount == (0x1234 + ac).uint16
  doAssert confirms[ac].first == nil and confirms[ac].last == nil
  doAssert buffers.backupQueues[ac].first == nil and buffers.backupQueues[ac].last == nil,
    "reset retained backup links to released descriptors"
  doAssert txlAcPending[ac] == 0 and not txlAcBusy[ac]
  doAssert writes[ac] == (0x24A00020'u, 1'u32 shl ac)
"""

CLEAR = r"""
for initiallyEnabled in [false, true]:
  for ac in 0'u8 .. 4'u8:
    setup()
    interrupts = initiallyEnabled
    statusSamples = @[1'u32 shl shifts[ac], 0'u32]
    doAssert txl_cntrl_clear_ac(ac)
    doAssert interrupts == initiallyEnabled and statusIndex == 2
    doAssert flushAcs == @[ac, ac]
    doAssert control.ac[ac].current == nil
    doAssert txlAcPending[ac] == 0 and not txlAcBusy[ac]
  setup()
  interrupts = initiallyEnabled
  statusSamples = @[1'u32, 0'u32]
  doAssert txl_cntrl_clear_bcn_ac()
  doAssert interrupts == initiallyEnabled and statusIndex == 2
  doAssert flushAcs == @[4'u8, 4]
  setup()
  interrupts = initiallyEnabled
  statusSamples = @[0'u32, 0, 0, 0, 0]
  doAssert txl_cntrl_clear_all_ac()
  doAssert interrupts == initiallyEnabled and statusIndex == 5
  doAssert flushAcs == @[4'u8, 4, 0, 0, 1, 1, 2, 2, 3, 3]
  doAssert active == 0
  for ac in 0 .. 4:
    doAssert control.ac[ac].current == nil
"""

REENTRY = r"""
for ac in 0'u8 .. 4'u8:
  setup()
  statusSamples = @[0'u32]
  var callbacks = 0
  let queue = ac
  onFlush = proc(flushed: uint8) =
    doAssert flushed == queue
    inc callbacks
    if callbacks == 1:
      doAssert confirms[queue].first == nil
      doAssert control.ac[queue].pending.first == nil
      doAssert control.ac[queue].current == nil
      doAssert buffers.backupQueues[queue].first == nil
      doAssert buffers.backupQueues[queue].last == nil
      doAssert (active and (1'u32 shl queue)) == 0
      confirms[queue] = CoList(first: cast[pointer](800), last: cast[pointer](801))
      control.ac[queue].pending = CoList(first: cast[pointer](900), last: cast[pointer](901))
      control.ac[queue].current = cast[pointer](902)
      buffers.backupQueues[queue] = CoList(first: cast[pointer](903), last: cast[pointer](904))
      txlAcPending[queue] = 1
      txlAcBusy[queue] = true
      active = active or (1'u32 shl queue)
  doAssert txl_cntrl_clear_ac(queue)
  doAssert callbacks == 2 and interrupts
  doAssert flushHeads == @[cast[pointer](600 + ac.int), cast[pointer](200 + ac.int)]
  doAssert confirms[queue] == CoList(first: cast[pointer](800), last: cast[pointer](801))
  doAssert control.ac[queue].pending == CoList(first: cast[pointer](900), last: cast[pointer](901))
  doAssert control.ac[queue].current == cast[pointer](902)
  doAssert buffers.backupQueues[queue] == CoList(first: cast[pointer](903), last: cast[pointer](904))
  doAssert txlAcPending[queue] == 1 and txlAcBusy[queue]
  doAssert (active and (1'u32 shl queue)) != 0
"""


@pytest.mark.parametrize("scenario", ["halt", "flush", "reset", "clear", "reentry"])
@pytest.mark.parametrize("release_mode", [False, True])
def test_tx_halt_flush_reset(scenario: str, release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    tx = (ROOT / "src/bl808/wifi/fw/tx_layer.nim").read_text()
    names = ["txl_buffer_reinit", "txl_buffer_reset", "txl_cntrl_halt_ac"]
    if scenario in ["flush", "reset", "clear", "reentry"]:
        names += ["txlDetachAc", "txl_cntrl_flush_ac"]
    if scenario == "reset":
        names.append("txl_reset")
    if scenario in ["clear", "reentry"]:
        names += ["txl_cntrl_clear_ac", "txl_cntrl_clear_bcn_ac", "txl_cntrl_clear_all_ac"]
    source = "\n".join(procedure(tx, name) for name in names)
    # The old C register workaround is replaced only in the test so its other
    # incorrect flush behavior can be reproduced on a native host compiler.
    source = re.sub(r'  \{\.emit: \[""".*?txl_buffer_reset\(\);.*?"""\]\.?\}',
                    "  txl_buffer_reset()", source, flags=re.S)
    check = {"halt": HALT, "flush": FLUSH, "reset": RESET, "clear": CLEAR,
             "reentry": REENTRY}[scenario]
    path = tmp_path / "tx_reset.nim"
    path.write_text(PLATFORM + source + SETUP + check)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
