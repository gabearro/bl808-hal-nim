"""Return the original GTK bytes used by the supplicant's repeat-key check."""

from pathlib import Path
import re

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_message_allocation import run_program
from test_wifi_security_readback import FW, PLATFORM


def source() -> str:
    mm = (FW / "kernel_mac_channel.nim").read_text()
    typedef = re.search(r"(?ms)^type\n  MmSecurityReadback = object.*?(?=^proc mmReadSecurityEntry)", mm)[0]
    body = procedure(mm, "mmReadSecurityEntry") + procedure(mm, "mm_sec_machwkey_get")
    body += procedure((FW / "platform_bl.nim").read_text(), "bl_wifi_get_sta_gtk")
    return typedef + PLATFORM + body + r'''
var original: array[32, uint8]
proc prepare(cipher: uint8; vif: uint8 = 0; slot: uint8 = 0) =
  setup()
  keyIndex = vif * 4 + slot
  let key = vifKeySlot(vifChannelForIdx(vif), slot.uint)
  key.cipherType = cipher
  vifs[vif].defaultKeyPtr = vifKeySlotPtr(addr vifs[vif], slot.uint)
  for i in 0..<original.len: original[i] = (0x17 + i * 7).uint8
  copyMem(addr bank[keyIndex].words[0], addr original[0], 16)
  if cipher == 1:
    # setKey stores the received and transmitted MIC keys in opposite order.
    copyMem(addr key.keyMaterial[0], addr original[24], 8)
    copyMem(addr key.keyMaterial[8], addr original[16], 8)
'''


CASES = {
    "cipher_lengths": r'''
for incoming in [false, true]:
  for vif in 0'u8..1:
    for slot in 0'u8..3:
      for cipher in [0'u8, 1, 2, 3]:
        prepare(cipher, vif, slot)
        irq = incoming
        var output: array[48, uint8]
        for value in output.mitems: value = 0xA5
        var size = 0xA6'u8
        let expectedLength = case cipher
          of 0: 5
          of 1: 32
          of 2: 16
          else: 13
        doAssert bl_wifi_get_sta_gtk(vif, addr output[8], addr size) == 0
        doAssert size.int == expectedLength, "incomplete GTK returned"
        for i in 0..<output.len:
          doAssert output[i] == (if i >= 8 and i < 8 + expectedLength: original[i - 8] else: 0xA5'u8)
        doAssert irq == incoming
''',
    "selection_and_failures": r'''
for failure in 0..10:
  prepare(1)
  var output: array[32, uint8]
  for value in output.mitems: value = 0xA5
  var size = 0xA6'u8
  case failure
  of 0: lookupStatus = 1
  of 1: keyIndex = 4 # Another VIF's key.
  of 2: keyIndex = 8 # A pairwise key, not a GTK.
  of 3: vifs[0].keys[0].installed = 0
  of 4: vifs[0].keys[0].cipherType = 5
  of 5: vifs[0].keys[0].keyIdx = 1
  of 6: vifs[0].keys[0].staIdx = 1
  of 7: vifs[0].defaultKeyPtr = 0
  of 8: idleSucceeds = false
  of 9: completionSucceeds = false
  else: failedIndex = 0
  doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == -1
  doAssert size == 0xA6 and irq
  for value in output: doAssert value == 0xA5
  if failure <= 7: doAssert commands.len == 0
''',
    "read_lifetime": r'''
for change in 0..5:
  prepare(1)
  var output: array[32, uint8]
  for value in output.mitems: value = 0xA5
  var size = 0xA6'u8
  readHook = proc() =
    case change
    of 0: inc rxVifEpochs[0]
    of 1:
      inc rxKeyRevision
      rxKeyLastChanged[7] = rxKeyRevision
    of 2: vifs[0].keys[0].installed = 0
    of 3: vifs[0].defaultKeyPtr = 0
    of 4: vifs[0].keys[0].cipherType = 2
    else: vifs[0].keys[0].keyIdx = 1
  doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == -1
  doAssert size == 0xA6 and irq
  for value in output: doAssert value == 0xA5

prepare(1)
readHook = proc() =
  inc rxKeyRevision
  rxKeyLastChanged[8] = rxKeyRevision
var output: array[32, uint8]
var size: uint8
doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == 0
doAssert output == original and size == 32

prepare(1)
rxKeyRevision = high(uint64)
readHook = proc() = rxKeyRevision = 1
size = 0xA6
doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == -1
doAssert size == 0xA6
''',
    "copy_completion": r'''
prepare(1)
var output: array[32, uint8]
var size = 0xA6'u8
copyHook = proc() =
  inc rxKeyRevision
  rxKeyLastChanged[7] = rxKeyRevision
doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == -1
doAssert size == 0xA6 and irq
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_gtk_readback(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vendor_repeat_gtk_comparison(tmp_path: Path, mode: str) -> None:
    from test_wifi_auth_frames import layouts

    root = FW.parents[3]
    vendor = (root / "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa.c").read_text()
    start = vendor.index("static bool wpa_supplicant_gtk_in_use(struct wpa_sm *sm, struct wpa_gtk_data *gd)\n{")
    stop = vendor.index("int wpa_supplicant_gtk_tx_bit_workaround", start)
    helper = vendor[start:stop]
    installer = "const STA_INFO_TAB_ENTRIES = 7\n"
    installer += layouts("SupplicantKeyParamView", "SupplicantTkipKeyDataView") + r'''
var
  writes: int
  nimFwDbgSetKey0, nimFwDbgSetKey1, nimFwDbgSetKey2, nimFwDbgSetKey3: uint32
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc supplicantTkipKeyData(req: ptr SupplicantKeyParamView): ptr SupplicantTkipKeyDataView =
  cast[ptr SupplicantTkipKeyDataView](addr req.keyData[0])
proc mm_sec_machwkey_wr(p: pointer): uint8 =
  doAssert not irq
  let req = cast[ptr SupplicantKeyParamView](p)
  doAssert req.keyType == 255
  inc writes
  result = req.keyIdx * 4 + req.addrIdx
  let key = vifKeySlot(vifChannelForIdx(req.keyIdx), req.addrIdx.uint)
  key.cipherType = req.translatedCipher
  key.keyIdx = result
  key.staIdx = req.addrIdx
  key.installed = 1
  copyMem(addr bank[result].words[0], addr req.keyData[0], 16)
  if req.translatedCipher == 1:
    copyMem(addr key.keyMaterial[0], addr req.keyData[16], 16)
''' + procedure((FW / "platform_bl.nim").read_text(), "setKey")
    bridge = r'''
{.emit: """
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
typedef unsigned char u8;
struct wpa_sm { u8 vif_idx; };
struct wpa_gtk_data { u8 gtk[32]; int gtk_len, keyidx, tx; };
extern int bl_wifi_get_sta_gtk(uint8_t, void *, void *);
#define wpa_printf(...) ((void)0)
''' + helper + r'''
static int test_repeat_gtk(uint8_t vif, const void *key, int length) {
    struct wpa_sm sm = { vif };
    struct wpa_gtk_data gd = { {0}, length, 0, 0 };
    memcpy(gd.gtk, key, length);
    return wpa_supplicant_gtk_in_use(&sm, &gd);
}
""".}
proc test_repeat_gtk(vif: uint8; key: pointer; length: cint): cint {.importc, nodecl.}
for cipher in [1'u8, 2]:
  prepare(cipher)
  let length = if cipher == 1: 32.cint else: 16.cint
  writes = 0
  doAssert setKey(0, 0, 0, nil, 0, addr original[0], length.csize_t, false) == 0
  doAssert writes == 1
  doAssert test_repeat_gtk(0, addr original[0], length) == 1,
    "vendor repeat-key comparison did not recognize the installed GTK"
  original[length - 1] = original[length - 1] xor 1
  doAssert test_repeat_gtk(0, addr original[0], length) == 0
  doAssert writes == 1
'''
    run_program(tmp_path, mode, source() + installer + bridge)
