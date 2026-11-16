"""CCMP PN zero admission with installed keys and actual RX dispatch bodies."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_decapsulation import CHECKS
from test_wifi_rx_mgt_counter import source as installed_key_source
from test_wifi_rx_mic_stream import source as dispatch_source


MODES = ["checked", "release", "asan", "firmware"]


def key_source() -> str:
    return installed_key_source() + procedure(
        (FW / "rx_upper.nim").read_text(), "rxuPnFresh") + r'''
proc checkAdmission(key: ptr VifKeySlotView; pn: uint64; tid: uint8;
                    accepted: bool) =
  env.secInfo0 = (pn and 0xFFFFFFFF'u64).uint32
  env.secInfo1 = (pn shr 32).uint32
  let before = key[]
  let beforeMgt = rxMgtReplayStates
  if tid < 8:
    doAssert rxuPnFresh(key, tid) == accepted, "PN preview disagreed"
    doAssert key[] == before and rxMgtReplayStates == beforeMgt,
      "PN preview changed counters"
  doAssert (receive(key, pn, tid) != 0) == accepted, "PN admission disagreed"
  if not accepted:
    doAssert key[] == before and rxMgtReplayStates == beforeMgt,
      "rejected PN changed counters or key material"
  else:
    let counter = if tid == RxuMgmtPnTid: addr rxMgtReplayStates[rxMgtKeyIndex(key)]
                  else: addr key.replayCounters[tid]
    let stored = (counter.pnHigh.uint64 shl 32) or counter.pnLow.uint64
    doAssert stored >= pn + 1
    var expected = before
    var expectedMgt = beforeMgt
    if tid == RxuMgmtPnTid: expectedMgt[rxMgtKeyIndex(key)] = counter[]
    else: expected.replayCounters[tid] = counter[]
    doAssert key[] == expected and rxMgtReplayStates == expectedMgt,
      "PN admission changed another counter or TX/key state"
'''


@pytest.mark.parametrize("mode", MODES)
def test_ccmp_zero_pn_with_installed_keys(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, key_source() + r'''
for index in 0 ..< rxMgtReplayStates.len:
  for windowed in [false, true]:
    for tid in 0'u8 .. RxuMgmtPnTid:
      for seed in [0'u64, 1, 32, 0xFFFFFFFF'u64, 1'u64 shl 37]:
        install(index, windowed, seed)
        let key = keyAt(index)
        doAssert key.cipherType == 2 and key.installed != 0
        key.pnLow = 0xAABBCCDD'u32
        key.pnHigh = 0x1234
        checkAdmission(key, 0, tid, false)
        let effectiveSeed = if index < STA_INFO_TAB_ENTRIES: 0'u64 else: seed
        if effectiveSeed != 0: checkAdmission(key, effectiveSeed, tid, false)
        checkAdmission(key, effectiveSeed + 1, tid, true)
        checkAdmission(key, effectiveSeed + 1, tid, false)
        checkAdmission(key, effectiveSeed + 10, tid, true)
        checkAdmission(key, effectiveSeed + 5, tid, windowed)
        checkAdmission(key, 0, tid, false)
        remove(index)
''')


@pytest.mark.parametrize("mode", MODES)
def test_tkip_initial_zero_and_generic_counter_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, key_source() + r'''
var generic: KeyReplayCounterView
doAssert replay_counter_validate(addr generic, 0)
doAssert not replay_counter_validate(addr generic, 0)
for index in 0 ..< rxMgtReplayStates.len:
  for windowed in [false, true]:
    # TKIP has no protected-management PN path.
    for tid in 0'u8 .. 7'u8:
      install(index, windowed, cipher = 1)
      let key = keyAt(index)
      doAssert key.cipherType == 1
      checkAdmission(key, 0, tid, true)
      checkAdmission(key, 0, tid, false)
      checkAdmission(key, 1, tid, true)
      checkAdmission(key, 0, tid, false)
      remove(index)
''')


DISPATCH = r'''
proc loadCcmp(fc: uint16; tid, keyId: uint8; pn: uint64; sequence: uint16;
               eapol: bool) =
  let savedKey = key
  let savedSequences = stations[0].sequences
  let headerLen = rxMacHeaderLen(fc).int + 8
  setup(fc, headerLen, 40, secure = true)
  key = savedKey
  stations[0].sequences = savedSequences
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 28
  macDataFrameAt(addr bytes[0]).seqCtrl = sequence
  if eapol and (fc and 0x100) != 0:
    macDataFrameAt(addr bytes[0]).addr3 = vifs[0].macAddr
  if (fc and 0x80) != 0:
    let offset = if (fc and 0x300) == 0x300: 30 else: 24
    bytes[offset] = tid
  let iv = rxSecurityHeaderAt[CcmpSecurityHeaderView](addr bytes[0],
                                                     (headerLen - 8).uint8)
  iv[] = default(CcmpSecurityHeaderView)
  iv.pn0 = (pn and 255).uint8
  iv.pn1 = ((pn shr 8) and 255).uint8
  iv.pn2 = ((pn shr 16) and 255).uint8
  iv.pn3 = ((pn shr 24) and 255).uint8
  iv.pn4 = ((pn shr 32) and 255).uint8
  iv.pn5 = ((pn shr 40) and 255).uint8
  iv.keyId = (keyId shl 6) or 0x20
  snapAt(headerLen, if eapol: 0x888E'u16 else: 0x0800'u16)

for fc in [0x4208'u16, 0x4288, 0x4388, 0xC288]:
  for windowed in [false, true]:
    for keyId in 0'u8 .. 3'u8:
      for priority in [0'u8, 3, 7]:
        if (fc and 0x80) == 0 and priority != 0: continue
        for eapol in [false, true]:
          setup(fc, rxMacHeaderLen(fc).int + 8, 40, secure = true)
          key = Key(cipherType: 2, staIdx: keyId, keyIdx: 8, installed: 1,
                    hasRxPn: windowed.uint8, pnLow: 0x11223344, pnHigh: 0x5566)
          for i in 0 ..< key.keyMaterial.len: key.keyMaterial[i] = (i + 0xA0).uint8
          for stage, pn in [0'u64, 1, 1, 10, 5, 0]:
            loadCcmp(fc, priority, keyId, pn, (0x1230 + stage * 16).uint16, eapol)
            let beforeKey = key
            let beforeSequences = stations[0].sequences
            let beforeBytes = bytes
            let accepted = stage == 1 or stage == 3 or (stage == 4 and windowed)
            let result = rxu_cntrl_frame_handle(addr mpdu)
            if not accepted:
              doAssert result == 0 and eapolCalls == 0 and transferred == 0 and prepared == 0,
                "rejected CCMP PN reached delivery"
              doAssert key == beforeKey and stations[0].sequences == beforeSequences,
                "rejected CCMP PN consumed state"
              doAssert bytes == beforeBytes, "rejected CCMP PN changed packet storage"
            else:
              var expected = beforeKey
              let counter = addr expected.replayCounters[priority]
              if stage != 4:
                counter.pnLow = (pn + 1).uint32
                counter.pnHigh = 0
              if windowed: counter.bitmap[0] = counter.bitmap[0] or (1'u32 shl (pn + 1))
              doAssert key == expected, "CCMP admission changed another counter or key"
              var sequences = beforeSequences
              if (fc and 0x80) != 0: sequences.qosSeqCtrl[priority] = (0x1230 + stage * 16).uint16
              else: sequences.nonQosSeqCtrl = (0x1230 + stage * 16).uint16
              doAssert stations[0].sequences == sequences
              if eapol:
                doAssert result == 0 and eapolCalls == 1 and transferred == 0 and prepared == 0
                doAssert eapolLength == 32 and eapolBytes.len == 32
                for i in 0 ..< 32:
                  doAssert eapolBytes[i] == beforeBytes[rxMacHeaderLen(fc).int + 16 + i]
              else:
                doAssert result == 1 and eapolCalls == 0 and transferred == 1 and prepared == 1
                doAssert sw.mpduLengthBytes == 46
'''


@pytest.mark.parametrize("mode", MODES)
def test_ccmp_zero_pn_before_rx_delivery(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, dispatch_source() + procedure(CHECKS, "snapAt") + DISPATCH)
