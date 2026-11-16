"""Connect RX dispatch, protected-header decode, Michael and replay state."""

from pathlib import Path
import random
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_michael import VECTORS, michael, nim_bytes, nim_string
from test_wifi_rx_decapsulation import CHECKS, dispatch_source


def source() -> str:
    code = dispatch_source()
    old_key = ("  Key = object\n    keyMaterial: array[152, uint8]\n"
               "    cipherType, staIdx: uint8\n  VifKeySlotView = Key\n")
    assert code.count(old_key) == 1
    types = layouts("KeyReplayCounterView", "VifKeySlotView", "MichaelMicContextView",
                    "TkipSecurityHeaderView", "CcmpSecurityHeaderView").removeprefix("type\n")
    code = code.replace(old_key, types + "  Key = VifKeySlotView\n"
                        "  ReplayCounterStateView = KeyReplayCounterView\n", 1)
    code = code.replace("bytes: array[2048, uint8]", "bytes: array[1744, uint8]")
    assert code.count("bytes: array[1744, uint8]") == 1
    for name in ["rxu_cntrl_protected_handle", "rxu_cntrl_check_pn", "rxuPnFresh",
                 "me_mic_init", "me_mic_calc", "me_mic_end"]:
        code = code.replace(procedure(code, name), "", 1)
    rx = (FW / "rx_upper.nim").read_text()
    core = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    real = "".join(procedure(core, name) for name in [
        "michael_block", "me_mic_init", "me_mic_calc", "me_mic_end"])
    real = re.sub(r"(?m)^\{\.emit:.*\n", "", real)
    real += procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate")
    for name in ["rxuTraceProtectedSlot", "rxu_cntrl_protected_handle", "rxu_cntrl_check_pn", "rxuPnFresh"]:
        real += procedure(rx, name)
    variables = sorted(name for name in set(re.findall(r"\bnimFwDbg\w+", real))
                       if not re.search(r"\b" + name + r"\s*:", code))
    helpers = "\n".join(f"var {name}: uint32" for name in variables) + r'''
template michaelMicContextAt(p: pointer): ptr MichaelMicContextView =
  cast[ptr MichaelMicContextView](p)
template replayCounterStateView(p: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc assert_err(cond, file: cstring; line: cint) =
  raise newException(AssertionDefect, $file & ":" & $line)
proc rxMgtReplayCounter(p: pointer): ptr KeyReplayCounterView = nil
proc rxuProtectedKey(env: ptr RxuCntrlEnvView; index: uint8;
                      flagged: bool): ptr VifKeySlotView =
  doAssert not flagged and index == key.staIdx
  addr key
'''
    generic = re.search(r"^proc rxSecurityHeaderAt\[T\].*?(?=^proc )", layout, re.M | re.S)
    assert generic is not None
    helpers += generic[0] + real
    handler = procedure(code, "rxu_cntrl_frame_handle")
    assert code.count(handler) == 1
    return code.replace(handler, helpers + handler, 1) + procedure(CHECKS, "setup")


HARNESS = r'''
var tails: array[2, array[1744, uint8]]
var nodes: array[2, Chain]
proc frameByte(offset: int): ptr uint8 =
  doAssert offset >= 0 and offset < 3 * 1736
  if offset < 1736: addr bytes[offset]
  else: addr tails[(offset - 1736) div 1736][offset mod 1736]
proc loadFrame(fc: uint16; tid: uint8; pn: uint64; sequence: uint16;
               msdu: string; mic: array[8, uint8]; localControl: bool; corrupt: int) =
  let savedKey = key
  let savedSequences = stations[0].sequences
  let headerLen = rxMacHeaderLen(fc).int + 8
  setup(fc, headerLen, msdu.len + 8, secure = true)
  key = savedKey
  stations[0].sequences = savedSequences
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 24
  macDataFrameAt(addr bytes[0]).seqCtrl = sequence
  if localControl and (fc and 0x100) != 0:
    macDataFrameAt(addr bytes[0]).addr3 = vifs[0].macAddr
  if (fc and 0x80) != 0:
    let offset = if (fc and 0x300) == 0x300: 30 else: 24
    bytes[offset] = tid
  let iv = rxSecurityHeaderAt[TkipSecurityHeaderView](addr bytes[0], (headerLen - 8).uint8)
  iv.tsc0 = (pn and 255).uint8
  iv.tsc1 = ((pn shr 8) and 255).uint8
  iv.wepSeed = (iv.tsc1 or 0x20) and 0x7F
  iv.keyId = (key.staIdx shl 6) or 0x20
  iv.tsc2 = ((pn shr 16) and 255).uint8
  iv.tsc3 = ((pn shr 24) and 255).uint8
  iv.tsc4 = ((pn shr 32) and 255).uint8
  iv.tsc5 = ((pn shr 40) and 255).uint8
  for buffer in tails.mitems:
    for value in buffer.mitems: value = 0xCD
  for index in 0 ..< nodes.len:
    nodes[index] = Chain(frameData: addr tails[index][0])
    if index + 1 < nodes.len: nodes[index].next = addr nodes[index + 1]
  if sw.mpduLengthBytes > 1736: chain.next = addr nodes[0]
  for offset, value in msdu: frameByte(headerLen + offset)[] = value.uint8
  for offset, value in mic: frameByte(headerLen + msdu.len + offset)[] = value
  if corrupt >= 0:
    let byte = frameByte(headerLen + msdu.len + corrupt)
    byte[] = byte[] xor 1
  for index in 1736 ..< bytes.len: bytes[index] = 0xDE
  for buffer in tails.mitems:
    for index in 1736 ..< buffer.len: buffer[index] = 0xDE

proc checkHistory(fc: uint16; tid, keyId: uint8; material: array[8, uint8];
                  msdu: string; mic: array[8, uint8]; eapol: bool; base: uint64) =
  for windowed in [false, true]:
    setup(fc, rxMacHeaderLen(fc).int + 8, msdu.len + 8, secure = true)
    key = Key(cipherType: 1, staIdx: keyId, keyIdx: 8, installed: 1,
      hasRxPn: windowed.uint8, pnLow: 0x11223344, pnHigh: 0x5566)
    for i in 0 ..< 8:
      key.keyMaterial[i] = material[i] xor 0xFF
      key.keyMaterial[8 + i] = material[i]
    var seen: seq[uint64]
    var highest: uint64
    for stage in 0 .. 5:
      let pn = if stage in [0, 3, 4]: base + 10 elif stage == 5: base + 5 else: base
      let corrupt = if stage in [0, 3]: keyId.int else: -1
      let sequence = (0x1230 + stage * 16).uint16
      loadFrame(fc, tid, pn, sequence, msdu, mic, eapol, corrupt)
      let beforeKey = key
      let beforeSequence = stations[0].sequences
      let beforeBytes = bytes
      let beforeTails = tails
      let accepted = stage == 1 or stage == 4 or (stage == 5 and windowed)
      let result = rxu_cntrl_frame_handle(addr mpdu)
      if not accepted:
        doAssert result == 0 and transferred == 0 and prepared == 0 and eapolCalls == 0,
          "rejected frame reached delivery"
        doAssert key == beforeKey, "rejected MIC/replay changed receive counters"
        doAssert stations[0].sequences == beforeSequence, "rejected frame consumed sequence state"
        doAssert bytes == beforeBytes and tails == beforeTails, "rejected frame changed packet storage"
      else:
        seen.add(pn)
        highest = max(highest, pn)
        var expected = beforeKey
        let counter = addr expected.replayCounters[tid]
        counter.pnLow = ((highest + 1) and 0xFFFFFFFF'u64).uint32
        counter.pnHigh = ((highest + 1) shr 32).uint32
        if windowed:
          counter.bitmap = default(typeof(counter.bitmap))
          for received in seen:
            let next = received + 1
            counter.bitmap[((next shr 5) and 1).int] =
              counter.bitmap[((next shr 5) and 1).int] or (1'u32 shl (next and 31).int)
        doAssert key == expected, "RX key state: fc=" & $fc & " tid=" & $tid &
          " base=" & $base & " stage=" & $stage & " window=" & $windowed &
          " actual=" & $key.replayCounters[tid] & " expected=" & $counter[]
        var expectedSequence = beforeSequence
        if (fc and 0x80) != 0: expectedSequence.qosSeqCtrl[tid] = sequence
        else: expectedSequence.nonQosSeqCtrl = sequence
        doAssert stations[0].sequences == expectedSequence
        if eapol:
          doAssert result == 0 and eapolCalls == 1 and transferred == 0 and prepared == 0
          doAssert eapolLength == (msdu.len - 8).uint32
          for i in 0 ..< eapolBytes.len: doAssert eapolBytes[i] == msdu[8 + i].uint8
        else:
          doAssert result == 1 and transferred == 1 and prepared == 1 and eapolCalls == 0
          let snap = cast[ptr LlcSnapHeaderView](addr beforeBytes[rxMacHeaderLen(fc).int + 8])
          let ethernetII = rxSnapIsRfc1042(snap) or rxSnapIsBridgeTunnel(snap)
          let headerLen = rxMacHeaderLen(fc).int + 8
          let strip = headerLen - (if ethernetII: 6 else: 14)
          doAssert sw.bufferOffset == strip.uint32
          doAssert sw.mpduLengthBytes.int == msdu.len + (if ethernetII: 6 else: 14)
          let payloadStart = if ethernetII: 8 else: 0
          for i in payloadStart ..< msdu.len:
            doAssert frameByte(headerLen + i)[] == msdu[i].uint8
        for i in 1736 ..< bytes.len: doAssert bytes[i] == 0xDE
        for buffer in tails:
          for i in 1736 ..< buffer.len: doAssert buffer[i] == 0xDE
'''


def history_program() -> str:
    for key, message, answer in VECTORS:
        assert michael(bytes.fromhex(key), message) == bytes.fromhex(answer)
    rng = random.Random(0x80852584D4943)
    rows = []
    index = 0
    for fc in [0x4208, 0x4288, 0x4388, 0xC288]:
        header = (32 if fc & 0x300 == 0x300 else 26 if fc & 0x80 else 24)
        if fc & 0x8080 == 0x8080:
            header += 4
        header += 8
        lengths = [12, 31, 64, *range(1736 - header - 8, 1736 - header + 2), 2352]
        for length in lengths:
            for protocol in [0x0800, 0x888E, 0x80F3, 0x8137, 1500]:
                material = rng.randbytes(8)
                tid = [0, 3, 7][index % 3] if fc & 0x80 else 0
                key_id = index % 4
                if protocol < 1536:
                    msdu = bytes([0x42, 0x42, 3]) + rng.randbytes(length - 3)
                else:
                    body = rng.randbytes(length - 8)
                    if protocol == 0x888E:
                        body = bytes([2, 3]) + (length - 12).to_bytes(2, "big") + body[4:]
                    oui = 0xF8 if protocol in [0x80F3, 0x8137] else 0
                    msdu = bytes([0xaa, 0xaa, 3, 0, 0, oui]) + protocol.to_bytes(2, "big") + body
                da = bytes([6, 11, 12, 13, 14, 15]) if fc & 0x100 and protocol != 0x888E else bytes([2, 1, 2, 3, 4, 5])
                sa = bytes([8, 16, 17, 18, 19, 20]) if fc & 0x300 == 0x300 else bytes([6, 11, 12, 13, 14, 15])
                mic = michael(material, da + sa + bytes([tid, 0, 0, 0]) + msdu)
                base = [0, 200, 0xFFFFFFFE, 1 << 37][index % 4]
                rows.append(f"checkHistory({fc}'u16, {tid}'u8, {key_id}'u8, {nim_bytes(material)}, "
                            f"{nim_string(msdu)}, {nim_bytes(mic)}, {str(protocol == 0x888E).lower()}, {base}'u64)")
                index += 1
    return source() + HARNESS + "\n" + "\n".join(rows)


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_rx_real_mic_before_replay_commit(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, history_program())


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_rx_foreign_control_port_and_short_mic(tmp_path: Path, mode: str) -> None:
    material = bytes.fromhex("0123456789abcdef")
    msdu = bytes.fromhex("aaaa03000000888e02030000")
    rows = []
    for fc in [0x4108, 0x4188, 0x4388]:
        tid = 3 if fc & 0x80 else 0
        da = bytes([6, 11, 12, 13, 14, 15])
        sa = bytes([8, 16, 17, 18, 19, 20]) if fc & 0x300 == 0x300 else bytes([4, 6, 7, 8, 9, 10])
        mic = michael(material, da + sa + bytes([tid, 0, 0, 0]) + msdu)
        rows.append(f"checkRejected({fc}'u16, {tid}'u8, {nim_bytes(material)}, "
                    f"{nim_string(msdu)}, {nim_bytes(mic)})")
    checks = r'''
proc checkRejected(fc: uint16; tid: uint8; material: array[8, uint8];
                    msdu: string; mic: array[8, uint8]) =
  for windowed in [false, true]:
    setup(fc, rxMacHeaderLen(fc).int + 8, msdu.len + 8, secure = true)
    key = Key(cipherType: 1, staIdx: 2, keyIdx: 8, installed: 1,
      hasRxPn: windowed.uint8)
    for i in 0 ..< 8: key.keyMaterial[8 + i] = material[i]
    for shortened in -1 .. 7:
      loadFrame(fc, tid, 200, 0x1230, msdu, mic, false, -1)
      if shortened >= 0:
        sw.mpduLengthBytes = rxMacHeaderLen(fc).uint16 + 8 + shortened.uint16
      let beforeKey = key
      let beforeSeq = stations[0].sequences
      let beforeBytes = bytes
      let beforeTails = tails
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert transferred == 0 and prepared == 0 and eapolCalls == 0
      doAssert key == beforeKey and stations[0].sequences == beforeSeq
      doAssert bytes == beforeBytes and tails == beforeTails
'''
    run_program(tmp_path, mode, source() + HARNESS + checks + "\n" + "\n".join(rows))
