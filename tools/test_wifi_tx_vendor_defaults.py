"""Direct byte-level checks for the vendor TX sequence and policy defaults."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TX_BUFFER_POOL_SIZE = 5
  MACHW_RNG_REG = 0x24B000A0'u
type
  Policies = object
    before: array[16, uint8]
    entries: array[5, TxBufferControlView]
    after: array[16, uint8]
  BcmcPolicies = object
    before: array[16, uint8]
    entries: array[2, TxBufferControlView]
    after: array[16, uint8]
var
  policies: Policies
  bcmc: BcmcPolicies
  bufferEnv: TxlBufferEnvView
  control: tuple[seqCounter: uint16]
  chainValues: array[14, uint8]
  powerValues: array[22, uint32]
  chainCalls, powerCalls: int
proc txControlEnv(): ptr typeof(control) = addr control
proc txlBufferEnvView(): ptr TxlBufferEnvView = addr bufferEnv
proc txBufferControlDescAt(index: int): ptr TxBufferControlView =
  doAssert index in 0 ..< policies.entries.len
  addr policies.entries[index]
proc txBufferControlBcmcDescAt(index: int): ptr TxBufferControlView =
  doAssert index in 0 ..< bcmc.entries.len
  addr bcmc.entries[index]
proc phy_get_ntx(): uint8 =
  doAssert chainCalls < chainValues.len
  result = chainValues[chainCalls]
  inc chainCalls
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_RNG_REG and powerCalls < powerValues.len
  result = powerValues[powerCalls]
  inc powerCalls
proc prepareDefaults(seed: int) =
  zeroMem(addr policies, sizeof(policies))
  zeroMem(addr bcmc, sizeof(bcmc))
  for b in policies.before.mitems: b = 0xA5
  for b in policies.after.mitems: b = 0xA5
  for b in bcmc.before.mitems: b = 0xA5
  for b in bcmc.after.mitems: b = 0xA5
  for b in bufferEnv.bufferEnvBaseToBackupQueuesPadding.mitems: b = 0xA5
  for i in 0 ..< policies.entries.len:
    for word in cast[ptr array[15, uint32]](addr policies.entries[i])[].mitems:
      word = 0xDEADBEAF'u32
  for i in 0 ..< bcmc.entries.len:
    for word in cast[ptr array[15, uint32]](addr bcmc.entries[i])[].mitems:
      word = 0xDEADBEAF'u32
  for i in 0 ..< bufferEnv.backupQueues.len:
    bufferEnv.backupQueues[i].first = cast[pointer](i * 2 + 1)
    bufferEnv.backupQueues[i].last = cast[pointer](i * 2 + 2)
  for i in 0 ..< chainValues.len: chainValues[i] = ((i + seed) mod 3).uint8
  for i in 0 ..< powerValues.len:
    powerValues[i] = 0xA5B60000'u32 or ((seed * 13 + i * 37 + 128).uint32 and 255)
  chainCalls = 0
  powerCalls = 0
static:
  doAssert sizeof(TxBufferControlView) == 60
  doAssert sizeof(MacDataFrameHeaderView) == 24
'''


def source() -> str:
    tx = (FW / "tx_layer.nim").read_text()
    return (layouts("MacDataFrameHeaderView", "TxBufferControlView",
                    "TxlBackupQueueView", "TxlBufferEnvView") + PLATFORM
            + procedure(tx, "txl_buffer_reinit") + procedure(tx, "txl_buffer_init")
            + procedure(tx, "txl_machdr_format"))


CASES = {
    "sequence_bytes": r'''
var bytes: array[64, uint8]
for offset in 1 .. 4:
  for initial in [0'u16, 1, 4094, 4095, 4096, 65534, 65535]:
    for fragment in 0'u8 .. 15:
      for oldHigh in [0'u8, 0x23, 0xFF]:
        for i in 0 ..< bytes.len: bytes[i] = (i * 17 + 3).uint8
        bytes[offset + 22] = 0xA0 or fragment
        bytes[offset + 23] = oldHigh
        let before = bytes
        control.seqCounter = initial
        txl_machdr_format(addr bytes[offset])
        let expectedCounter = (initial.uint32 + (fragment == 0).uint32) and 0xFFFF
        let expectedWord = ((expectedCounter and 0xFFF) shl 4) or fragment.uint32
        doAssert control.seqCounter == expectedCounter.uint16
        for i in 0 ..< bytes.len:
          let expected = if i == offset + 22: (expectedWord and 255).uint8
            elif i == offset + 23: (expectedWord shr 8).uint8
            else: before[i]
          doAssert bytes[i] == expected
''',
    "fragment_train": r'''
var headers: array[17, MacDataFrameHeaderView]
control.seqCounter = 4094
for fragment in 0 .. 15:
  headers[fragment].seqCtrl = fragment.uint16
  txl_machdr_format(addr headers[fragment])
  doAssert control.seqCounter == 4095
  doAssert headers[fragment].seqCtrl == (0xFFF0'u16 or fragment.uint16)
txl_machdr_format(addr headers[16])
doAssert control.seqCounter == 4096 and headers[16].seqCtrl == 0
''',
    "policy_words": r'''
for seed in 0 .. 19:
  prepareDefaults(seed)
  txl_buffer_init()
  doAssert chainCalls == 14 and powerCalls == 22
  for index in 0 .. 6:
    var expected: array[15, uint32]
    expected[0] = 0xBADCAB1E'u32
    expected[1] = chainValues[index * 2].uint32 shl 14
    expected[2] = (1'u32 shl (chainValues[index * 2 + 1].uint32 + 1)) - 1
    expected[4] = 0xFFFF0704'u32
    expected[14] = 0x003F0000'u32
    if index < 5:
      for retry in 0 .. 3: expected[9 + retry] = powerValues[index * 4 + retry] and 255
      expected[13] = 0x2200
    else:
      expected[9] = powerValues[20 + index - 5] and 255
    let actual = if index < 5: addr policies.entries[index] else: addr bcmc.entries[index - 5]
    doAssert cast[ptr array[15, uint32]](actual)[] == expected
  for i in 0 .. 15:
    doAssert policies.before[i] == 0xA5 and policies.after[i] == 0xA5
    doAssert bcmc.before[i] == 0xA5 and bcmc.after[i] == 0xA5
  for b in bufferEnv.bufferEnvBaseToBackupQueuesPadding: doAssert b == 0xA5
  for queue in bufferEnv.backupQueues:
    doAssert queue.first == nil and queue.last == nil
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_tx_vendor_defaults(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize(("case", "old", "new"), [
    ("sequence_bytes", "seqCtrlByte and 0x0F'u8", "seqCtrlByte and 0x03'u8"),
    ("fragment_train", "txCtrl.seqCounter + 1  #", "txCtrl.seqCounter + 2  #"),
    ("policy_words", "bcmcTxPolicyDesc.retryTxPowerControl2 = 0",
     "discard # leave the old retry-power word"),
])
def test_oracle_rejects_wrong_fields(tmp_path: Path, case: str, old: str, new: str) -> None:
    code = source()
    assert code.count(old) == 1
    code = code.replace(old, new, 1)
    with pytest.raises(AssertionError, match="AssertionDefect"):
        run_program(tmp_path, "checked", code + CASES[case])
