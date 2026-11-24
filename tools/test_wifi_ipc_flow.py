"""Check embedded IPC acknowledgement and configuration register separation."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  CoList = object
    first, last: pointer
  Env = object
    hostTxList, hostTxCfmList: ptr CoList
  Shared = object
    hostTxListCursor, hostTxCfmCursor: CoList
  Operation = tuple[kind: char, address: uint, value: uint32]
var
  env: Env
  shared: Shared
  ipcEmbEnv: pointer
  ipcEmbEnvStruct: array[5, uint32]
  allocationToken: uint32
  rawStatus, unmask, configLow, configHigh, events: uint32
  magic = 0x49504332'u32
  reads: seq[uint]
  operations: seq[Operation]
  allocations, clears, assertions: int
  missingTaskCallback, missingTaskHandle: bool
  nimFwDbgIpcTxFlowOn, nimFwDbgIpcTxFlowOff: uint32
proc ipcEmbEnvView(): ptr Env = addr env
proc ipcSharedEnvView(): ptr Shared = addr shared
proc allocate(): pointer {.cdecl.} =
  inc allocations
  if missingTaskHandle: nil else: addr allocationToken
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 0x44
  if missingTaskCallback: nil else: cast[pointer](allocate)
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert p == (addr ipcEmbEnvStruct[0]) and value == 0 and size == 20
  zeroMem(p, size.int)
  env = default(Env)
  inc clears
  p
proc assert_err(condition, file: cstring; line: int) =
  doAssert line == 183
  inc assertions
proc assert_rec(condition, file: cstring; line: int) =
  doAssert line == 0
  inc assertions
proc regRead(address: uint): uint32 =
  reads.add(address)
  case address
  of 0x24800104'u: rawStatus
  of 0x2480011C'u: rawStatus and unmask
  of 0x24800114'u: configLow
  of 0x24800118'u: configHigh
  of 0x24800140'u: magic
  else: raiseAssert "unexpected IPC read"
proc regWrite(address: uint; value: uint32) =
  operations.add(('w', address, value))
  case address
  of 0x24800108'u: rawStatus = rawStatus and not value
  of 0x2480010C'u: unmask = unmask or value
  of 0x24800110'u: unmask = unmask and not value
  of 0x24800114'u: configLow = value
  of 0x24800118'u: configHigh = value
  else: raiseAssert "unexpected IPC write"
proc ke_evt_set(mask: uint32) =
  operations.add(('s', 0'u, mask))
  events = events or mask
proc ke_evt_clear(mask: uint32) =
  operations.add(('c', 0'u, mask))
  events = events and not mask
proc setup(status: uint32; mask = 0xFFFFFFFF'u32) =
  rawStatus = status
  unmask = mask
  configLow = 0xB6CDE123'u32
  configHigh = 0x5A3C9876'u32
  events = 0x80000040'u32
  reads.setLen(0)
  operations.setLen(0)
  allocations = 0
  clears = 0
  assertions = 0
  missingTaskCallback = false
  missingTaskHandle = false
  magic = 0x49504332'u32
  ipcEmbEnv = nil
  ipcEmbEnvStruct = [1'u32, 2, 3, 4, 5]
  env = default(Env)
  nimFwDbgIpcTxFlowOn = 0
  nimFwDbgIpcTxFlowOff = 0
'''


def source() -> str:
    constants = (FW / "register_constants.nim").read_text().split("\nwhen defined", 1)[0]
    ipc = (FW / "ipc_embedded.nim").read_text()
    return constants + PLATFORM + "".join(
        procedure(ipc, name) for name in [
            "ipc_emb_init", "ipc_emb_tx_irq", "ipc_emb_cfmback_irq",
            "ipc_emb_tx_flow_on", "ipc_emb_tx_flow_off",
        ]
    )


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_interrupt_acknowledges_only_sampled_pending_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bits in 0'u32 .. 31:
  for mask in [0'u32, 0x1500'u32, 0xFFFFFFFF'u32]:
    let status = (bits shl 8) or 0x80000022'u32
    setup(status, mask)
    let pending = status and mask and 0x1F00'u32
    ipc_emb_tx_irq()
    doAssert reads == @[0x2480011C'u]
    doAssert rawStatus == (status and not pending), "TX IPC status was not acknowledged"
    doAssert unmask == (mask and not pending)
    doAssert configLow == 0xB6CDE123'u32 and configHigh == 0x5A3C9876'u32
    doAssert events == (0x80000040'u32 or (pending shl 1))
    if pending == 0:
      doAssert operations.len == 0
    else:
      doAssert operations == @[
        ('s', 0'u, pending shl 1),
        ('w', 0x24800110'u, pending),
        ('w', 0x24800108'u, pending)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_flow_reenable_does_not_replay_acknowledged_tx_interrupt(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0x1F02)
ipc_emb_tx_irq()
let firstEvents = events
operations.setLen(0)
ipc_emb_tx_flow_on(3)
ipc_emb_tx_irq()
doAssert operations == @[('w', 0x2480010C'u, 0x1F00'u32)],
  "re-enabling TX flow replayed an already handled interrupt"
doAssert rawStatus == 2 and events == firstEvents
doAssert nimFwDbgIpcTxFlowOn == 1
operations.setLen(0)
ipc_emb_tx_flow_off(1)
doAssert operations == @[('w', 0x24800110'u, 0x1F00'u32),
                        ('c', 0'u, 0x3E00'u32)]
doAssert events == 0x80000040'u32 and nimFwDbgIpcTxFlowOff == 1
doAssert configLow == 0xB6CDE123'u32 and configHigh == 0x5A3C9876'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initialization_keeps_vendor_configuration_writes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0xA5001F00'u32, 0)
ipc_emb_init()
doAssert ipcEmbEnv == (addr allocationToken) and allocations == 1 and clears == 1
doAssert ipcEmbEnvStruct == [0'u32, 0, 0, 0, 0]
doAssert env.hostTxList == (addr shared.hostTxListCursor)
doAssert env.hostTxCfmList == (addr shared.hostTxCfmCursor)
let configValues = [0'u32, 4, 0x204, 0xA04, 0x2A04, 0x32A04,
                    0xF2A04, 0x3F2A04, 0xFF2A04, 0x3FF2A04]
var expected: seq[Operation] = @[
  ('w', 0x24800114'u, 0'u32), ('w', 0x24800118'u, 0'u32)]
var expectedReads = @[0x24800140'u]
for value in configValues:
  expected.add(('w', 0x24800114'u, value))
  expectedReads.add(0x24800114'u)
expected.add(('w', 0x2480010C'u, 0x1F03'u32))
doAssert operations == expected and reads == expectedReads
doAssert configLow == 0x3FF2A04'u32 and configHigh == 0
doAssert rawStatus == 0xA5001F00'u32 and unmask == 0x1F03
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initialization_stops_on_bad_ipc_magic(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0xA5001F00'u32, 0)
magic = 0
ipc_emb_init()
doAssert assertions == 1 and allocations == 1 and clears == 1
doAssert ipcEmbEnv == nil
doAssert reads == @[0x24800140'u]
doAssert operations.len == 0
doAssert configLow == 0xB6CDE123'u32 and configHigh == 0x5A3C9876'u32
doAssert unmask == 0 and rawStatus == 0xA5001F00'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initialization_stops_without_task_binding(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for missingCallback in [false, true]:
  setup(0xA5001F00'u32, 0)
  ipcEmbEnv = addr allocationToken
  missingTaskCallback = missingCallback
  missingTaskHandle = not missingCallback
  ipc_emb_init()
  doAssert ipcEmbEnv == nil and assertions == 1
  doAssert allocations == (if missingCallback: 0 else: 1)
  doAssert clears == 0 and reads.len == 0 and operations.len == 0
  doAssert ipcEmbEnvStruct == [1'u32, 2, 3, 4, 5]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_confirmation_ack_uses_same_bank_without_changing_configuration(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bits in 0'u32 .. 3:
  setup((bits shl 4) or 0x100'u32)
  ipc_emb_cfmback_irq()
  var expected: seq[Operation]
  var expectedEvents = 0x80000040'u32
  if (bits and 2) != 0:
    expected.add(('w', 0x24800110'u, 0x20'u32))
    expected.add(('w', 0x24800108'u, 0x20'u32))
    expected.add(('s', 0'u, 0x00100000'u32))
    expectedEvents = expectedEvents or 0x00100000'u32
  if (bits and 1) != 0:
    expected.add(('w', 0x24800110'u, 0x10'u32))
    expected.add(('w', 0x24800108'u, 0x10'u32))
    expected.add(('s', 0'u, 0x00200000'u32))
    expectedEvents = expectedEvents or 0x00200000'u32
  doAssert operations == expected and events == expectedEvents
  doAssert rawStatus == 0x100 and reads == @[0x2480011C'u]
  doAssert configLow == 0xB6CDE123'u32 and configHigh == 0x5A3C9876'u32
''')
