"""Known-answer and independent differential checks of production AES/CMAC/BIP."""

from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

import pytest

from test_wifi_mfp_control import KEY_CONTEXT


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
import std/os
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< size.int: bytes[i] = value.uint8
  p
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc assert_warn(a, b: cstring; line: cint) = discard
"""

MFP_PLATFORM = r"""
type
  HostTxDescView = object
    vifIdx, staInfoIdx: uint8
  Keys = object
    groupKeyPtr: pointer
  Vif = object
    keys: Keys
    slots: array[6, VifKeySlotView]
  Sta = object
    capabilityFlags: uint32
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
var
  vifs: array[2, Vif]
  stations: array[7, Sta]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txSecurityBind(d: ptr HostTxDescView; key: ptr VifKeySlotView; bip: bool): bool = true
proc txlFrameLeaseToken(desc: ptr HostTxDescView): uint32 = 1
proc txlFrameLeaseMatches(desc: ptr HostTxDescView; token: uint32): bool = token == 1
proc txlFrameSessionCurrent(desc: ptr HostTxDescView): bool = true
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifKeyPointers(v: ptr Vif): ptr Keys = addr v.keys
proc vifKeySlot(v: ptr Vif; i: uint): ptr VifKeySlotView = addr v.slots[i]
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc mfpMgmtFramePolicyView(p: pointer): ptr MfpMgmtFramePolicyView =
  cast[ptr MfpMgmtFramePolicyView](p)
proc mmieAt(p: pointer): ptr MmIeView = cast[ptr MmIeView](p)
proc ieCursorAfter(p: pointer; n: uint): pointer = cast[pointer](cast[uint](p) + n)
proc mac_ie_find(p: pointer; length: uint32; id: uint8): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  var at = 0'u32
  while at + 2 <= length:
    let size = bytes[at + 1].uint32 + 2
    if size > length - at: return nil
    if bytes[at] == id: return ieCursorAfter(p, at.uint)
    at += size
"""

CHECKS = r"""
proc read32(data: string; at: int): uint32 =
  for i in 0 ..< 4: result = result or (data[at + i].uint32 shl (i * 8))
let wire = readFile(paramStr(1))
var at = 0
while at < wire.len:
  let kind = read32(wire, at)
  let length = read32(wire, at + 4).int
  let headerLen = read32(wire, at + 8)
  at += 12
  var key: array[16, uint8]
  for i in 0 ..< 16: key[i] = wire[at + i].uint8
  at += 16
  var data = wire[at ..< at + length]
  at += length
  var expected: array[16, uint8]
  for i in 0 ..< 16: expected[i] = wire[at + i].uint8
  at += 16
  var guarded: array[48, uint8]
  for b in guarded.mitems: b = 0x5A
  let outPtr = addr guarded[16]
  let input = if data.len == 0: nil else: cast[pointer](addr data[0])
  case kind
  of 0:
    var schedule: array[176, uint8]
    aes128_expand_key(addr key[0], addr schedule[0])
    copyMem(outPtr, input, 16)
    aes_encrypt_block(addr schedule[0], outPtr)
  of 1:
    hsu_aes_cmac(addr key[0], input, length.uint32, outPtr)
  of 2:
    var keySlot: array[160, uint8]
    for b in keySlot.mitems: b = 0xA5
    copyMem(addr keySlot[136], addr key[0], 16)
    let beforeKey = keySlot
    let beforeFrame = data
    let mic = mfp_compute_bip(addr keySlot[0], input, length.uint32, headerLen)
    for i in 0 ..< 16:
      guarded[16 + i] = if i < 8: ((mic shr (i * 8)) and 255).uint8 else: 0
    doAssert keySlot == beforeKey and data == beforeFrame
  of 3:
    copyMem(outPtr, input, 16)
    aes_cmac_shift_sub_key(outPtr)
  of 4:
    copyMem(outPtr, addr key[0], 16)
    xor_halfwords(outPtr, input, (length div 2).uint32)
  of 5:
    var ctx: AesCmacContext
    aesCmacInit(ctx, addr key[0])
    var offset, step: int
    const chunks = [1, 7, 16, 17, 3, 32]
    while offset < length:
      aesCmacUpdate(ctx, nil, 0)
      let count = min(chunks[step mod chunks.len], length - offset)
      aesCmacUpdate(ctx, addr data[offset], count.uint32)
      offset += count
      inc step
    aesCmacUpdate(ctx, nil, 0)
    aesCmacFinish(ctx, outPtr)
  of 6:
    for vifIndex in 0'u8 .. 1'u8:
      vifs = default(typeof(vifs))
      let slot = addr vifs[vifIndex].slots[headerLen]
      slot.keyMaterial = key
      slot.staIdx = headerLen.uint8
      slot.installed = 1
      slot.cipherType = 5
      slot.pnLow = 0xFFFFFFFF'u32
      vifs[vifIndex].keys.groupKeyPtr = slot
      var buffer = newSeq[uint8](length + 50)
      for b in buffer.mitems: b = 0x5A
      let frame = addr buffer[16]
      copyMem(frame, input, length)
      var desc = HostTxDescView(vifIdx: vifIndex)
      doAssert mfp_add_mgmt_mic(addr desc, frame, length.uint32) == 18
      let mmie = mmieAt(addr buffer[16 + length])
      doAssert mmie.ie.id == 76 and mmie.ie.len == 16 and mmie.keyId == headerLen.uint16
      doAssert slot.pnLow == 0 and slot.pnHigh == 1
      doAssert mmie.ipn == [0'u8, 0, 0, 0, 1, 0]
      for i in 0 ..< 8:
        doAssert mmie.mic[i] == expected[i], "generated BIP MIC"
      for i in 0 ..< 16:
        doAssert buffer[i] == 0x5A and buffer[34 + length + i] == 0x5A
      var status = MfpMgmtFramePolicyView(frameCtrl: 0xC0, bodyOffset: 24,
                                         staIdx: 0, vifIdx: vifIndex, flags: 1)
      var upload = 1'u8
      var flags = 0'u8
      buffer[41] = buffer[41] xor 1
      doAssert mfp_ignore_mgmt_frame(addr status, frame, (length + 18).uint16,
                                    addr upload, addr flags)
      doAssert upload == 0 and slot.replayCounters[0].pnLow == 0 and slot.replayCounters[0].pnHigh == 0
      buffer[41] = buffer[41] xor 1
      upload = 1
      doAssert not mfp_ignore_mgmt_frame(addr status, frame, (length + 18).uint16,
                                        addr upload, addr flags)
      doAssert upload == 1
      doAssert slot.replayCounters[0].pnLow == 1 and slot.replayCounters[0].pnHigh == 1
      doAssert mfp_ignore_mgmt_frame(addr status, frame, (length + 18).uint16,
                                    addr upload, addr flags)
      doAssert upload == 0
    for i in 0 ..< 16: guarded[16 + i] = expected[i]
  else: doAssert false
  for i in 0 ..< 16:
    doAssert guarded[i] == 0x5A and guarded[i + 32] == 0x5A
    doAssert guarded[i + 16] == expected[i],
      "kind=" & $kind & " length=" & $length & " recordEnd=" & $at &
      " byte=" & $i & " actual=" & $guarded[i + 16] & " expected=" & $expected[i]

vifs = default(typeof(vifs))
var untouched: array[64, uint8]
for b in untouched.mitems: b = 0x5A
let before = untouched
var desc = HostTxDescView(vifIdx: 0)
doAssert mfp_add_mgmt_mic(addr desc, addr untouched[0], 26) == 0
doAssert untouched == before
vifs[0].keys.groupKeyPtr = addr vifs[0].slots[4]
for length in [0'u32, 23, 65518, high(uint32)]:
  doAssert mfp_add_mgmt_mic(addr desc, addr untouched[0], length) == 0
  doAssert untouched == before
desc.vifIdx = 2
doAssert mfp_add_mgmt_mic(addr desc, addr untouched[0], 26) == 0
doAssert mfp_add_mgmt_mic(nil, addr untouched[0], 26) == 0
doAssert mfp_add_mgmt_mic(addr desc, nil, 26) == 0
doAssert untouched == before
"""


def procedure(source: str, name: str) -> str:
    start = re.search(rf"^proc {name}\*?\(", source, re.M)
    assert start
    end = re.search(r"^(?:proc|template|func|const|type|var)\b", source[start.end():], re.M)
    return source[start.start():start.end() + end.start() if end else len(source)]


def production() -> str:
    mac = (FW / "kernel_mac_channel.nim").read_text()
    crypto = (FW / "crypto_mfp_hsu.nim").read_text()
    source = PLATFORM
    layout = (FW / "layout_types.nim").read_text()
    source += "type\n"
    for name in ["KeyReplayCounterView", "VifKeySlotView", "MacIeView", "MmIeView",
                 "MfpMgmtFramePolicyView"]:
        source += re.search(rf"^  {name} .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    source += MFP_PLATFORM + KEY_CONTEXT
    for name in ["xor_halfwords", "add_round_key", "aes_cmac_shift_sub_key"]:
        source += procedure(mac, name)
    aes = "const AES_SBOX" + crypto.split("const AES_SBOX", 1)[1].split(
        "proc aes128_encrypt_copy", 1)[0]
    source += aes + procedure(crypto, "hsu_aes_cmac")
    if "proc mfp_compute_bip" not in aes:
        source += procedure(crypto, "mfp_compute_bip")
    source += procedure(mac, "mfp_is_robust_frame")
    source += procedure(crypto, "mfp_add_mgmt_mic")
    source += procedure(crypto, "mfpIgnoreRxMgmtFrame")
    source += procedure(crypto, "mfp_ignore_mgmt_frame")
    return source + CHECKS


def record(kind: int, key: bytes, data: bytes, expected: bytes, header: int = 0) -> bytes:
    assert len(key) == 16 and len(expected) <= 16
    return struct.pack("<III", kind, len(data), header) + key + data + expected.ljust(16, b"\0")


def run_vectors(tmp_path: Path, vectors: bytes) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "aes_test.nim"
    path.write_text(production())
    data = tmp_path / "vectors.bin"
    data.write_bytes(vectors)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}",
         str(path), str(data)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


def test_aes_and_cmac_known_answers(tmp_path: Path) -> None:
    key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    msg = bytes.fromhex(
        "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
        "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    vectors = record(0, bytes(range(16)), bytes.fromhex("00112233445566778899aabbccddeeff"),
                     bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a"))
    for length, tag in [(0, "bb1d6929e95937287fa37d129b756746"),
                        (16, "070a16b46b4d4144f79bdd9dd04a287c"),
                        (40, "dfa66747de9ae63030ca32611497c827"),
                        (64, "51f0bebf7e3b9d92fc49741779363cfe")]:
        vectors += record(1, key, msg[:length], bytes.fromhex(tag))
        vectors += record(5, key, msg[:length], bytes.fromhex(tag))
    for length in range(42):
        vectors += record(2, key, bytes(length), bytes(8), 24)
    for header in [0, 23, 43, 44, 0xFFFFFFFF]:
        vectors += record(2, key, bytes(42), bytes(8), header)
    run_vectors(tmp_path, vectors)


def test_aes_cmac_and_bip_differential(tmp_path: Path) -> None:
    pytest.importorskip("cryptography")
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    rng = random.Random(0x808B1F)
    vectors = bytearray()
    for length in [*range(0, 97), 127, 128, 129, 255, 256, 257, 511, 512, 1024, 1500]:
        key, data = rng.randbytes(16), rng.randbytes(length)
        mac = cmac.CMAC(algorithms.AES(key))
        mac.update(data)
        vectors += record(1, key, data, mac.finalize())
        mac = cmac.CMAC(algorithms.AES(key))
        mac.update(data)
        vectors += record(5, key, data, mac.finalize())
        block = rng.randbytes(16)
        cipher = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        vectors += record(0, key, block, cipher.update(block) + cipher.finalize())
        doubled = (int.from_bytes(block, "big") << 1) & ((1 << 128) - 1)
        if block[0] & 128:
            doubled ^= 0x87
        vectors += record(3, key, block, doubled.to_bytes(16, "big"))
        for count in range(0, 17, 2):
            expected = bytes(a ^ b for a, b in zip(key[:count], block[:count])) + key[count:]
            vectors += record(4, key, block[:count], expected)

    for header in [24, 28, 32]:
        for length in [*range(header + 18, header + 83), 512, 1500]:
            key = rng.randbytes(16)
            frame = bytearray(rng.randbytes(length))
            frame[0:2] = ((int.from_bytes(frame[:2], "little") & ~0xFC) | 0xC0).to_bytes(2, "little")
            fc = int.from_bytes(frame[:2], "little") & 0xC7FF
            aad = fc.to_bytes(2, "little") + frame[4:22]
            mac = cmac.CMAC(algorithms.AES(key))
            mac.update(aad + frame[header:-8] + bytes(8))
            vectors += record(2, key, frame, mac.finalize()[:8], header)
    run_vectors(tmp_path, bytes(vectors))


def test_bip_append_receive_roundtrip(tmp_path: Path) -> None:
    pytest.importorskip("cryptography")
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import algorithms

    rng = random.Random(0xB1B808)
    vectors = bytearray()
    for key_id in [4, 5]:
        for extra in range(64):
            key = rng.randbytes(16)
            frame = bytearray(bytes.fromhex("c0000000") + rng.randbytes(18) + bytes(2))
            frame[4] |= 1
            frame += b"\x03\x00" + bytes([221, extra]) + rng.randbytes(extra)
            mmie = b"\x4c\x10" + key_id.to_bytes(2, "little") + b"\x00\x00\x00\x00\x01\x00" + bytes(8)
            mac = cmac.CMAC(algorithms.AES(key))
            mac.update(frame[:2] + frame[4:22] + frame[24:] + mmie)
            vectors += record(6, key, frame, mac.finalize()[:8], key_id)
    run_vectors(tmp_path, bytes(vectors))
