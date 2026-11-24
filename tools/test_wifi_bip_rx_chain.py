"""Execute BIP admission with production AES/CMAC and noncontiguous RX buffers."""
from pathlib import Path
import random
import re

import pytest

from test_wifi_aes_cmac import MFP_PLATFORM, PLATFORM
from test_wifi_message_allocation import run_program
from test_wifi_mfp_control import FW, KEY_CONTEXT, procedure


RX = r'''
type
  RxBuffer = object
    next, frameData: pointer
  RxSwDescView = object
    bufferChain: pointer
    mpduLengthBytes: uint16
var
  descriptor: uint8
  rx: RxSwDescView
  buffers: array[3, array[1744, uint8]]
  beforeBuffers: array[3, array[1744, uint8]]
  chains: array[2, RxBuffer]
  flat, beforeFlat: array[4096, uint8]
  currentGeneration = 7'u32
  keyCalls: int
  replaceAt: int
  observeMemory: bool
proc rxFrameBufferChainAt(p: pointer): ptr RxBuffer = cast[ptr RxBuffer](p)
proc rxPayloadDescIndex(p: pointer): int =
  if p == (addr chains[0]): 0 elif p == (addr chains[1]): 1 else: -1
proc rxFrameCursor(p: pointer; n: uint): pointer = cast[pointer](cast[uint](p) + n)
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  if p == addr descriptor: addr rx else: nil
proc rxFramePayload(p: ptr RxSwDescView): pointer =
  rxFrameBufferChainAt(p.bufferChain).frameData
proc rxUploadGeneration(p: pointer): uint32 = currentGeneration
proc rxUploadCurrent(p: pointer; g: uint32): bool =
  p == (addr descriptor) and g == currentGeneration
proc rxStationCurrent(p: pointer): bool = p == addr descriptor
proc rxKeyCurrent(p, key: pointer): bool =
  inc keyCalls
  if keyCalls == replaceAt: inc currentGeneration
  p == addr descriptor
proc memoryObservation() =
  if observeMemory:
    doAssert buffers == beforeBuffers and flat == beforeFlat,
      "BIP receive temporarily changed RX frame bytes"
'''


def source() -> str:
    crypto = (FW / "crypto_mfp_hsu.nim").read_text()
    mac = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = "proc memoryObservation()\n" + PLATFORM.replace(
        "  copyMem(dst, src, size.int)", "  memoryObservation()\n  copyMem(dst, src, size.int)", 1)
    code += "type\n"
    for name in ["KeyReplayCounterView", "VifKeySlotView", "MacIeView", "MmIeView", "MfpMgmtFramePolicyView"]:
        code += re.search(rf"^  {name} .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    code += MFP_PLATFORM + KEY_CONTEXT.replace("proc rxKeyCurrent(desc, key: pointer): bool = true\n", "") + RX
    code += "type\n" + re.search(r"^  RxFrameIdentity .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    lower = (FW / "rx_layer.nim").read_text()
    code += procedure(lower, "rxFrameCurrent") + procedure(lower, "rxCaptureFrame")
    code += procedure((FW / "rx_upper.nim").read_text(), "rxuCopyFrameBytes")
    for name in ["xor_halfwords", "add_round_key", "aes_cmac_shift_sub_key"]:
        code += procedure(mac, name)
    code += "const AES_SBOX" + crypto.split("const AES_SBOX", 1)[1].split("proc aes128_encrypt_copy", 1)[0]
    code += procedure(mac, "mfp_is_robust_frame") + procedure(crypto, "mfpIgnoreRxMgmtFrame")
    code += procedure(crypto, "mfp_ignore_mgmt_frame")
    return code + r'''
var status: MfpMgmtFramePolicyView
var upload, flags: uint8
var chosenVif, chosenSlot: int
var total: uint16
proc selected(): ptr VifKeySlotView = addr vifs[chosenVif].slots[chosenSlot]
proc setup(data: seq[uint8]; vif, slot: int; enabled: bool) =
  chosenVif = vif
  chosenSlot = slot
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  flat = default(typeof(flat))
  for b in buffers.mitems:
    for x in b.mitems: x = 0xCD
  for i, value in data:
    flat[i] = value
    if i < 1736: buffers[0][i] = value
    else: buffers[2][i - 1736] = value
  chains[1] = RxBuffer(frameData: addr buffers[2][0])
  chains[0] = RxBuffer(frameData: addr buffers[0][0], next: addr chains[1])
  rx = RxSwDescView(bufferChain: addr chains[0], mpduLengthBytes: data.len.uint16)
  total = data.len.uint16
  selected().installed = 1
  selected().cipherType = 5
  selected().staIdx = slot.uint8
  for i in 0..<16: selected().keyMaterial[i] = i.uint8
  vifs[vif].keys.groupKeyPtr = selected()
  stations[0].capabilityFlags = 8
  status = MfpMgmtFramePolicyView(frameCtrl: data[0].uint16 or (data[1].uint16 shl 8),
    bodyOffset: 24, staIdx: 0, vifIdx: vif.uint8, flags: 1)
  beforeBuffers = buffers
  beforeFlat = flat
  upload = 1
  flags = 0xA0
  keyCalls = 0
  replaceAt = 0
  currentGeneration = 7
  rxKeyRevision = 1
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
  interrupts = enabled
  observeMemory = false
proc receive(bound: bool; captured = 7'u32): bool =
  if bound:
    var verified = true
    let ignored = mfpIgnoreRxMgmtFrame(addr descriptor, addr status, addr buffers[0][0],
      total, addr upload, addr flags, captured, addr verified)
    doAssert verified == not ignored
    ignored
  else:
    mfp_ignore_mgmt_frame(addr status, addr flat[0], total, addr upload, addr flags)
proc checkUnchanged(enabled: bool) =
  doAssert buffers == beforeBuffers and flat == beforeFlat and interrupts == enabled
  doAssert flags == 0xA0
'''


def frame(length: int, slot: int, action: bool = False) -> bytes:
    pytest.importorskip("cryptography")
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import algorithms

    rng = random.Random(0xB1808 + length + slot)
    data = bytearray(rng.randbytes(24))
    data[:2] = (0x00D0 if action else 0x00C0).to_bytes(2, "little")
    data[4] |= 1
    body = bytearray([5, 0, 255, 255, 0] if action else [3, 0])
    extra = length - 24 - len(body) - 18
    assert extra >= 0 and extra != 1
    if extra % 2:
        body += bytes([221, 1, 77])
        extra -= 3
    body += bytes([221, 0]) * (extra // 2)
    mmie = bytes([76, 16]) + slot.to_bytes(2, "little") + (3).to_bytes(6, "little") + bytes(8)
    data += body + mmie
    mac = cmac.CMAC(algorithms.AES(bytes(range(16))))
    mac.update(bytes(data[:2] + data[4:22] + data[24:]))
    data[-8:] = mac.finalize()[:8]
    assert len(data) == length
    return bytes(data)


def literal(data: bytes) -> str:
    return "@[" + ",".join(f"{v}'u8" for v in data) + "]"


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", ["tail", "chain", "readonly", "generation", "controls", "invalid"])
def test_bip_rx(case: str, mode: str, tmp_path: Path) -> None:
    lengths = [47, 49, 64, 97] if case == "tail" else (
        [1735, 1736, 1737, 1743, 1753, 1754, 1755, 1757, 1758, 1759, 1760, 1761, 1765, 2328]
        if case in ["chain", "invalid"] else [44, 64, 97])
    tests = ""
    for slot in [4, 5]:
        for length in lengths:
            tests += "\nblock:\n  let data = " + literal(frame(length, slot, case == "tail")) + "\n"
            tests += f"  for vif in 0..<2:\n    for enabled in [false, true]:\n      setup(data, vif, {slot}, enabled)\n"
            if case in ["tail", "chain"]:
                tests += '''      doAssert not receive(true), "valid BIP frame was rejected"
      doAssert upload == 1 and selected().replayCounters[0].pnLow == 4
      checkUnchanged(enabled)
      doAssert receive(true) and upload == 0, "duplicate BIP frame was accepted"
'''
            elif case == "readonly":
                tests += '''      observeMemory = true
      doAssert not receive(true) and upload == 1
      checkUnchanged(enabled)
'''
            elif case == "generation":
                tests += '''      for point in [0, 1, 2]:
        setup(data, vif, SLOT, enabled)
        replaceAt = point
        if point == 0: currentGeneration = 8
        doAssert receive(true), "BIP committed replay state after RX replacement"
        doAssert upload == 0 and selected().replayCounters[0].pnLow == 0
        checkUnchanged(enabled)
'''.replace("SLOT", str(slot))
            elif case == "controls":
                tests += '''      doAssert not receive(false) and upload == 1
      checkUnchanged(enabled)
      setup(data, vif, SLOT, enabled)
      flat[total.int - 1] = flat[total.int - 1] xor 1
      beforeFlat = flat
      doAssert receive(false) and upload == 0
      doAssert selected().replayCounters[0].pnLow == 0
      checkUnchanged(enabled)
'''.replace("SLOT", str(slot))
            else:
                tests += '''      for fault in 0..6:
        setup(data, vif, SLOT, enabled)
        let at = total.int - (if fault == 0: 1 elif fault == 1: 18 elif fault == 2: 17 else: 16)
        if fault < 4:
          if at < 1736: buffers[0][at] = buffers[0][at] xor 1
          else: buffers[2][at - 1736] = buffers[2][at - 1736] xor 1
        elif fault == 4:
          rx.mpduLengthBytes = total - 1
        elif fault == 5:
          if total <= 1736: continue
          chains[0].next = nil
        else:
          rx.bufferChain = nil
        beforeBuffers = buffers
        doAssert receive(true) and upload == 0
        doAssert selected().replayCounters[0].pnLow == 0
        checkUnchanged(enabled)
'''.replace("SLOT", str(slot))
    run_program(tmp_path, mode, source() + tests)
