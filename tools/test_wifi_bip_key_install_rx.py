"""Connect production IGTK installation to BIP verification and replay state."""
from pathlib import Path
import re

import pytest

from test_wifi_bip_rx_chain import frame, literal, source as receive_source
from test_wifi_message_allocation import run_program
from test_wifi_mfp_control import FW, procedure


def source() -> str:
    code = receive_source().replace("    groupKeyPtr: pointer", "    groupKeyPtr, defaultKeyPtr: pointer")
    layout = (FW / "layout_types.nim").read_text()
    code += "\ntype\n" + re.search(
        r"^  VifMgmtAddKeyParamView .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    code += r'''
type ReplayCounterStateView = KeyReplayCounterView
const
  RC_PRNG_MULT = 0x41C64E6D'u32
  RC_PRNG_INCR = 0x3039'u32
var
  vifKeyPrngState = 1'u32
  replayResets: int
  rxMgtReplayStates: array[19, KeyReplayCounterView]
  rxMgtReplayValid: array[19, bool]
proc vifMgmtAddKeyParamView(p: pointer): ptr VifMgmtAddKeyParamView =
  cast[ptr VifMgmtAddKeyParamView](p)
proc vifKeySlotPtr(vif: ptr Vif; slot: uint): pointer = vifKeySlot(vif, slot)
proc vifMgmtAddKeyTkipMaterialPtr(p: ptr VifMgmtAddKeyParamView): pointer =
  addr p.tkipKeyMaterial[0]
proc replayCounterStateView(p: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](p)
proc le32(p: pointer): uint32 =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0..<4: result = result or (bytes[i].uint32 shl (8 * i))
proc rxKeyChange(key: pointer) =
  inc replayResets
  inc rxKeyRevision
  rxKeyLastChanged[rxMgtKeyIndex(key)] = rxKeyRevision
'''
    code += procedure((FW / "rx_upper.nim").read_text(), "rxMgtReplayReset")
    code += (FW / "key_install_policy.nim").read_text()
    code += procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate")
    vif = (FW / "vif_management.nim").read_text()
    code += procedure(vif, "vifReuseBipKey") + procedure(vif, "vif_mgmt_add_key")
    return code + r'''
var request: VifMgmtAddKeyParamView
proc setSeed(seed: uint64) =
  for i in 0..<4:
    request.pnLowBytes[i] = ((seed shr (8 * i)) and 255).uint8
    request.pnHighBytes[i] = ((seed shr (32 + 8 * i)) and 255).uint8
proc install(seed: uint64; fresh: bool; changed = false) =
  if fresh:
    selected()[] = default(VifKeySlotView)
    replayResets = 0
    rxMgtReplayStates = default(typeof(rxMgtReplayStates))
    rxMgtReplayValid = default(typeof(rxMgtReplayValid))
    request = VifMgmtAddKeyParamView(keySlot: chosenVif.uint8, staIdx: chosenSlot.uint8,
      cipherType: 5, keyLen: 16, macLen: 6)
    for i in 0..<16: request.ccmpKeyMaterial[i] = i.uint8
  if changed: request.ccmpKeyMaterial[0] = request.ccmpKeyMaterial[0] xor 0x80
  setSeed(seed)
  let beforeRequest = request
  vif_mgmt_add_key(addr request, (15 + chosenVif * 2 + chosenSlot - 4).uint8)
  doAssert request == beforeRequest
proc nextPn(): uint64 =
  selected().replayCounters[0].pnLow.uint64 or
    (selected().replayCounters[0].pnHigh.uint64 shl 32)
proc expectSeed(seed: uint64) =
  for counter in selected().replayCounters:
    doAssert counter.pnLow == ((seed + 1) and 0xFFFFFFFF'u64).uint32
    doAssert counter.pnHigh == ((seed + 1) shr 32).uint32
    doAssert counter.bitmap == [0'u32, 0]
  let index = rxMgtKeyIndex(selected())
  doAssert rxMgtReplayValid[index]
  doAssert rxMgtReplayStates[index] == selected().replayCounters[0]
proc expectReceive(bound, accepted, enabled: bool) =
  let beforeKey = selected()[]
  upload = 1
  doAssert receive(bound) == not accepted, "BIP installation/reception decision"
  doAssert upload == accepted.uint8
  if not accepted: doAssert selected()[] == beforeKey
  checkUnchanged(enabled)
'''


def bip_frame(length: int, slot: int, pn: int, changed: bool = False) -> bytes:
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import algorithms

    data = bytearray(frame(length, slot))
    data[-14:-8] = pn.to_bytes(6, "little")
    data[-8:] = bytes(8)
    key = bytearray(range(16))
    if changed:
        key[0] ^= 0x80
    mac = cmac.CMAC(algorithms.AES(bytes(key)))
    mac.update(data[:2] + data[4:22] + data[24:])
    data[-8:] = mac.finalize()[:8]
    return bytes(data)


CASES = ["zero", "nonzero", "reinstall", "rekey", "exhausted", "bad-mic"]


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_bip_key_install_rx(case: str, mode: str, tmp_path: Path) -> None:
    pytest.importorskip("cryptography")
    seeds = [1, 31, 32, 0xFFFFFFFF, 0x100000000, 0xFFFFFFFFFFFE] if case == "nonzero" else [0]
    if case == "exhausted":
        seeds = [0xFFFFFFFFFFFF]
    tests = ""
    for seed in seeds:
        for slot in [4, 5]:
            for length in [44, 1757, 2328]:
                pn = seed if case in ["zero", "nonzero", "exhausted"] else seed + 1
                changed = case == "rekey"
                tests += "\nblock:\n  let data = " + literal(bip_frame(length, slot, pn, changed)) + "\n"
                tests += f"""  for vif in 0..<2:
    for enabled in [false, true]:
      for bound in [false, true]:
        setup(data, vif, {slot}, enabled)
        install({seed}'u64, true)
"""
                if case in ["zero", "nonzero", "exhausted"]:
                    tests += "        expectReceive(bound, false, enabled)\n"
                    tests += f"        expectSeed({seed}'u64)\n"
                    if case != "exhausted":
                        fresh = literal(bip_frame(length, slot, seed + 1))
                        tests += f"        setup({fresh}, vif, {slot}, enabled)\n"
                        tests += f"        install({seed}'u64, true)\n"
                        tests += "        expectReceive(bound, true, enabled)\n"
                        tests += f"        doAssert nextPn() == {seed + 2}'u64\n"
                        tests += "        expectReceive(bound, false, enabled)\n"
                elif case == "reinstall":
                    tests += """        expectReceive(bound, true, enabled)
        selected().pnLow = 17
        selected().pnHigh = 3
        let before = selected()[]
        let revision = rxKeyRevision
        let management = rxMgtReplayStates
        for repeatedSeed in [0'u64, 1, 9, 0xFFFFFFFFFFFF'u64]:
          install(repeatedSeed, false)
          doAssert selected()[] == before and rxKeyRevision == revision
          doAssert rxMgtReplayStates == management and replayResets == 1
          expectReceive(bound, false, enabled)
"""
                elif case == "rekey":
                    tests += """        selected().replayCounters[0].pnLow = 100
        selected().pnLow = 19
        install(0, false, true)
        expectSeed(0)
        doAssert replayResets == 2 and selected().pnLow == 0
        expectReceive(bound, true, enabled)
        doAssert nextPn() == 2
        expectReceive(bound, false, enabled)
"""
                else:
                    tests += """        let at = total.int - 1
        flat[at] = flat[at] xor 1
        if at < 1736: buffers[0][at] = buffers[0][at] xor 1
        else: buffers[2][at - 1736] = buffers[2][at - 1736] xor 1
        beforeFlat = flat
        beforeBuffers = buffers
        expectReceive(bound, false, enabled)
        expectSeed(0)
"""
    run_program(tmp_path, mode, source() + tests)
