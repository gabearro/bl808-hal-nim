"""Check local and public RF calibration snapshots against vendor MMIO order."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type, source


def state_type(text: str, name: str) -> str:
    start = text.index("  " + name + " = object\n")
    lines = text[start:].splitlines(keepends=True)
    body = [lines[0]]
    for line in lines[1:]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line)
    return "type\n" + "".join(body)


def state_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True) + object_type(rf, "RfDfeInitBlock")
    code += state_type(rf, "RfPriCalState") + state_type(rf, "RfPriVendorCalState")
    code += r'''
var
  dfe: RfDfeInitBlock
  bl808RfPriVendorCalState: RfPriVendorCalState
  nimFwDbgRfCalSaveCount, nimFwDbgRfCalRestoreCount: uint32
  nimFwDbgRfCalSaveRf2c, nimFwDbgRfCalSaveRf88: uint32
  nimFwDbgRfCalRestoreRf2c, nimFwDbgRfCalRestoreRf88: uint32
  nimFwDbgRfCalRestoreReadbackRf2c, nimFwDbgRfCalRestoreReadbackRf88: uint32
  nimFwDbgRfCalRestoreRf8c: uint32
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
'''
    for name in ("saveRfPriCalState", "restoreRfPriCalState",
                 "rf_pri_save_state_before_cal", "rf_pri_restore_state_after_cal"):
        code += procedure(rf[rf.rindex("\nproc " + name + "(") + 1:], name)
    return code + r'''
const VendorRfOffsets = [0x04, 0x2C, 0x1C, 0x30, 0xB8, 0xC0, 0xC4,
                        0x88, 0x90, 0x600, 0x60C, 0x618, 0x61C, 0x48,
                        0x20C, 0x214, 0x218, 0x23C, 0x240, 0x244, 0xF0,
                        0x64, 0x58, 0x220, 0x74, 0xA4]
proc snapshotSetup() =
  setup()
  for word in registerStorage.mitems: word = randomWord()
  let words = cast[ptr UncheckedArray[uint32]](addr dfe)
  for i in 0 ..< sizeof(dfe) div 4: words[i] = randomWord()
proc vendorAddresses(): seq[uint] =
  for i, offset in VendorRfOffsets:
    if i == 7: result.add(cast[uint](addr dfe.hbnCtrl30))
    result.add(cast[uint](addr registerStorage[offset div 4]))
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("public", [False, True])
def test_snapshot_fields_and_restore_ownership(tmp_path: Path, mode: str, public: bool) -> None:
    run_program(tmp_path, mode, state_source() + f"const PublicSnapshot = {str(public).lower()}\n" + r'''
for vector in 0 ..< 1000:
  snapshotSetup()
  let savedRf = registerStorage
  let savedDfe = dfe
  var local: RfPriCalState
  let saves = nimFwDbgRfCalSaveCount
  let restores = nimFwDbgRfCalRestoreCount
  when PublicSnapshot: rf_pri_save_state_before_cal()
  else: local = saveRfPriCalState()
  doAssert mmioReads == vendorAddresses(), "snapshot reads RF8C instead of RF90, or differs in order"
  doAssert mmioWrites.len == 0
  doAssert nimFwDbgRfCalSaveCount == saves + 1
  doAssert nimFwDbgRfCalSaveRf2c == savedRf[0x2C div 4]
  doAssert nimFwDbgRfCalSaveRf88 == savedRf[0x88 div 4]
  for word in registerStorage.mitems: word = randomWord()
  let dfeWords = cast[ptr UncheckedArray[uint32]](addr dfe)
  for i in 0 ..< sizeof(dfe) div 4: dfeWords[i] = randomWord()
  var expected = registerStorage
  var expectedDfe = dfe
  expectedDfe.hbnCtrl30 = savedDfe.hbnCtrl30
  for offset in VendorRfOffsets: expected[offset div 4] = savedRf[offset div 4]
  mmioReads.setLen(0)
  when PublicSnapshot: rf_pri_restore_state_after_cal()
  else: restoreRfPriCalState(local)
  doAssert registerStorage == expected and dfe == expectedDfe,
    "restore must recover RF90 and leave RF8C/unowned registers live"
  var wanted: seq[tuple[address: uint, value: uint32]]
  for address in vendorAddresses(): wanted.add((address, cast[ptr uint32](address)[]))
  doAssert mmioWrites == wanted, "snapshot restore stores differ from vendor order"
  doAssert nimFwDbgRfCalRestoreCount == restores + 1
  doAssert nimFwDbgRfCalRestoreRf8c == expected[0x8C div 4]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_local_snapshots_remain_independent_of_public_storage(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, state_source() + r'''
snapshotSetup()
let outerRf = registerStorage
let outer = saveRfPriCalState()
for word in registerStorage.mitems: word = randomWord()
let innerRf = registerStorage
let inner = saveRfPriCalState()
rf_pri_save_state_before_cal()
for word in registerStorage.mitems: word = randomWord()
restoreRfPriCalState(outer)
for offset in VendorRfOffsets: doAssert registerStorage[offset div 4] == outerRf[offset div 4]
restoreRfPriCalState(inner)
for offset in VendorRfOffsets: doAssert registerStorage[offset div 4] == innerRf[offset div 4]
''')
