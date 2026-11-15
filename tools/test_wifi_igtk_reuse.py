"""Preserve live BIP counters when the same IGTK is installed again."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_vif_keys import FW, build_source, procedure


SETUP = r'''
var
  resets: int
  request: VifMgmtAddKeyParamView
  key: ptr VifKeySlotView
  hardwareIndex: uint8
proc setup(vif, slot: uint8) =
  vifs = default(typeof(vifs))
  resets = 0
  request = VifMgmtAddKeyParamView(keySlot: vif, staIdx: slot,
    cipherType: 5, keyLen: 16, macLen: 6)
  hardwareIndex = 15 + vif * 2 + slot - 4
  for i in 0..<16: request.ccmpKeyMaterial[i] = (i + 1).uint8
  request.pnLowBytes[0] = 3
  vif_mgmt_add_key(addr request, hardwareIndex)
  key = vifKeySlot(vifChannelForIdx(vif), slot.uint)
  key.pnLow = 111
  key.pnHigh = 7
  for i in 0..<8:
    key.replayCounters[i] = KeyReplayCounterView(pnLow: (20 + i).uint32,
      pnHigh: 5, bitmap: [0x1234'u32, 0x5678])
'''


CASES = {
    "same_key": r'''
let before = key[]
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert key[] == before, "repeated IGTK installation reset live counters"
doAssert resets == 1, "same IGTK changed the key revision"
''',
    "request_pn": r'''
let before = key[]
for sequence in [0'u32, 2, 3, 1000, high(uint32)]:
  for i in 0..<4: request.pnLowBytes[i] = ((sequence shr (8 * i)) and 255).uint8
  vif_mgmt_add_key(addr request, hardwareIndex)
  doAssert key[] == before and resets == 1
''',
    "reselect": r'''
let before = key[]
let otherSlot = if request.staIdx == 4: 5'u else: 4'u
vifKeyPointers(vifChannelForIdx(request.keySlot)).groupKeyPtr =
  vifKeySlotPtr(vifChannelForIdx(request.keySlot), otherSlot)
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert key[] == before and resets == 1
doAssert vifKeyPointers(vifChannelForIdx(request.keySlot)).groupKeyPtr ==
  vifKeySlotPtr(vifChannelForIdx(request.keySlot), request.staIdx.uint)
''',
    "changed_key": r'''
for byte in 0..<16:
  request.ccmpKeyMaterial[byte] = request.ccmpKeyMaterial[byte] xor 1
  key.pnLow = 9
  vif_mgmt_add_key(addr request, hardwareIndex)
  doAssert key.keyMaterial == request.ccmpKeyMaterial and resets == 2 + byte
  doAssert key.pnLow == 0 and key.pnHigh == 0
  doAssert key.replayCounters[0].pnLow == 4 and key.replayCounters[0].pnHigh == 0
''',
    "exhausted": r'''
key.pnLow = high(uint32)
key.pnHigh = 0xFFFF
key.replayCounters[0].pnLow = 0
key.replayCounters[0].pnHigh = 0x10000
let before = key[]
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert key[] == before and resets == 1, "reinstall reopened an exhausted IGTK"
''',
    "fresh_metadata": r'''
key.installed = 0
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert resets == 2 and key.pnLow == 0 and key.installed == 1
key.pnLow = 9
key.keyIdx = 200
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert resets == 3 and key.pnLow == 0 and key.keyIdx == hardwareIndex
key.pnLow = 9
key.staIdx = 0
vif_mgmt_add_key(addr request, hardwareIndex)
doAssert resets == 4 and key.pnLow == 0 and key.staIdx == request.staIdx
''',
}


def source(checks: str) -> str:
    body = procedure((FW / "vif_management.nim").read_text(), "vif_mgmt_add_key")
    code = build_source(body, "")
    code = code.replace("proc rxMgtReplayReset(key: pointer) = discard",
                        "var resets: int\nproc rxMgtReplayReset(key: pointer) = inc resets")
    setup = SETUP.replace("  resets: int\n", "")
    return code + setup + "\nfor vif in 0'u8..1:\n  for slot in 4'u8..5:\n    setup(vif, slot)\n" + "\n".join(
        "    " + line if line else "" for line in checks.splitlines()
    )


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_igtk_reuse(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source(CASES[case]))


def transaction_source() -> str:
    from test_wifi_auth_frames import layouts
    from test_wifi_station_keys import WRITE_PLATFORM, harness, proc_body

    platform = WRITE_PLATFORM.replace(
        "    index: uint8\n", "    index: uint8\n    groupKeyPtr, defaultKeyPtr: uint32\n"
        "    slots: array[6, VifKeySlotView]\n", 1)
    platform = platform.replace(procedure(platform, "vif_mgmt_add_key"), "", 1)
    platform = platform.replace(procedure(platform, "vifKeySlotPtr"), "", 1)
    support = r'''
var
  vifKeyPrngState = 1'u32
  pending: bool
  beginCalls, revision: int
proc vifKeySlot(vif: ptr Vif; slot: uint): ptr VifKeySlotView = addr vif.slots[slot]
proc vifKeySlotPtr(vif: ptr Vif; slot: uint): uint32 = pointerAddrU32(vifKeySlot(vif, slot))
proc vifKeyPointers(vif: ptr Vif): ptr Vif = vif
proc vifMgmtAddKeyParamView(p: pointer): ptr VifMgmtAddKeyParamView =
  cast[ptr VifMgmtAddKeyParamView](p)
proc rxMgtReplayReset(key: pointer) = inc revision
proc rxKeyChange(key: pointer) = inc revision
proc txSecurityKeyUpdatePending(key: pointer): bool = pending
proc txSecurityBeginUpdate(key: pointer): bool =
  inc beginCalls
  if pending: return false
  pending = true
  event("quiesce")
  true
proc txSecurityEndUpdate(key: pointer) = pending = false
proc replay_counter_validate(key: pointer; pn: uint64): bool = true
proc le32(p: pointer): uint32 =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0..<4: result = result or (bytes[i].uint32 shl (8 * i))
'''
    vif = (FW / "vif_management.nim").read_text()
    code = layouts("KeyReplayCounterView", "VifKeySlotView", "VifMgmtAddKeyParamView")
    code += harness(platform, support, (FW / "key_install_policy.nim").read_text(),
                    procedure(vif, "vifReuseBipKey"), procedure(vif, "vif_mgmt_add_key"),
                    proc_body((FW / "kernel_mac_channel.nim").read_text(), "mm_sec_machwkey_wr"),
                    replay_stubs=False, tx_update_stubs=False)
    return code + r'''
for incoming in [false, true]:
  for vif in 0'u8..1:
    for slot in 4'u8..5:
      setup(incoming)
      vifs = default(typeof(vifs))
      vifs[1].index = 1
      pending = false
      beginCalls = 0
      revision = 0
      var req = requestFor(5, true)
      req.keyIdx = vif
      req.addrIdx = slot
      let hardware = 15 + vif * 2 + slot - 4
      doAssert mm_sec_machwkey_wr(addr req) == hardware
      doAssert beginCalls == 1 and revision == 1 and not pending and irq == incoming
      let key = vifKeySlot(vifChannelForIdx(vif), slot.uint)
      key.pnLow = 97
      key.pnHigh = 3
      for counter in key.replayCounters.mitems:
        counter = KeyReplayCounterView(pnLow: 123, pnHigh: 7, bitmap: [5'u32, 9])
      let before = key[]
      events.setLen(0)
      doAssert mm_sec_machwkey_wr(addr req) == hardware
      doAssert key[] == before and beginCalls == 1 and revision == 1 and events.len == 0
      # The early reuse path must not bypass an in-progress update.
      pending = true
      doAssert mm_sec_machwkey_wr(addr req) == 0xFF
      doAssert key[] == before and beginCalls == 2 and revision == 1
      pending = false
      # A different IGTK still takes the normal quiesce/install path.
      req.keyWords[3] = req.keyWords[3] xor 1
      doAssert mm_sec_machwkey_wr(addr req) == hardware
      doAssert beginCalls == 3 and revision == 2 and not pending
      doAssert key.pnLow == 0 and key.pnHigh == 0 and key[] != before
      doAssert irq == incoming
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_igtk_transaction_reuse(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, transaction_source())


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_live_update_query(tmp_path: Path, mode: str) -> None:
    from test_wifi_tx_key_update import queue_program

    run_program(tmp_path, mode, queue_program() + r'''
queueReset(true)
doAssert not txSecurityKeyUpdatePending(addr key)
onConfirmation = proc() =
  doAssert txSecurityKeyUpdatePending(addr key)
  doAssert not txSecurityKeyUpdatePending(addr secondKey)
doAssert txSecurityBeginUpdate(addr key)
doAssert txSecurityKeyUpdatePending(addr key)
txSecurityEndUpdate(addr key)
doAssert not txSecurityKeyUpdatePending(addr key)
doAssert not txSecurityKeyUpdatePending(nil)
''')
