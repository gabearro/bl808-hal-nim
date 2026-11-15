"""Keep RX dispatch tied to its frame across allocation callbacks."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx


SUPPORT = r'''
var
  action: proc()
  keyValid = true
  extraBytes: array[1736, uint8]
  extraChain: Chain
  replacementBytes: array[2048, uint8]
  replacementSw: RxSwDescView
  messageSends, messageFrees, frameCopies: int
  capturedSource: array[6, uint8]
  sentMessage: MicFailure
  messageStorage: pointer
proc invoke() =
  if action != nil:
    let callback = action
    action = nil
    callback()
proc ke_msg_free_payload(p: pointer) =
  doAssert p == messageStorage
  inc messageFrees
  dealloc(p)
  messageStorage = nil
proc replaceFrame() =
  inc rxGeneration
  # Same address and peer, but a new descriptor generation.
  # Keep the same extent so a length check alone cannot reject the replacement.
  sw.frameControlFlags = 0x5A5A1234
  sw.bufferOffset = 9
  bytes[20] = 0xE1
  bytes[40] = 0xE2
  envState.secInfo0 = 0xAABBCCDD'u32
  envState.secInfo1 = 0x44332211'u32
  replacementBytes = bytes
  replacementSw = sw
proc resetHooks() =
  action = nil
  keyValid = true
  frameCopies = 0
  messageSends = 0
  messageFrees = 0
  sentMessage = default(MicFailure)
  messageStorage = nil
  capturedSource = default(typeof(capturedSource))
proc prepareEapol() =
  setup(0x0208, 24, 1748)
  resetHooks()
  snapAt(24, 0x888E)
  for b in extraBytes.mitems: b = 0x6A
  extraChain = Chain(frameData: addr extraBytes[0])
  chain.next = addr extraChain
proc prepareMic() =
  setup(0x4208, 32, 40, secure = true)
  resetHooks()
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 24'u32
  snapAt(32, 0x0806)
  key.staIdx = 3
  stations[0].macAddr = [2'u8, 9, 8, 7, 6, 5]
  badMic = true
'''


def replace_procedure(source: str, name: str, body: str) -> str:
    old = rx.procedure(source, name)
    return source.replace(old, body + "\n\n", 1)


def source() -> str:
    code = rx.dispatch_source()
    marker = "proc rxu_cntrl_frame_handle*"
    before, handler = code.split(marker, 1)
    before = before.replace(
        "proc rxKeyCurrent(desc, key: pointer): bool = true",
        "proc rxKeyCurrent(desc, key: pointer): bool",
        1,
    )
    before = replace_procedure(before, "allocateEapol", r'''
proc allocateEapol(length: uint32): pointer {.cdecl.} =
  inc allocations
  invoke()
  if not allocationFails: result = alloc(length.int)
''')
    before = replace_procedure(before, "ke_msg_alloc", r'''
proc ke_msg_alloc(id: uint16; dst, src, length: int): pointer =
  doAssert id == 0xC04 and dst == 9 and src == 3 and length == 24
  invoke()
  if not allocationFails:
    result = alloc0(sizeof(MicFailure))
    messageStorage = result
''')
    before = replace_procedure(before, "ke_msg_send", r'''
proc ke_msg_send(p: pointer) =
  doAssert p == messageStorage
  sentMessage = cast[ptr MicFailure](p)[]
  inc messageSends
  dealloc(p)
  messageStorage = nil
''')
    if "proc ke_msg_free_payload(" in before:
        before = replace_procedure(before, "ke_msg_free_payload", "")
    before = replace_procedure(before, "c_memcpy", r'''
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  inc frameCopies
  copyMem(dst, src, size.int)
  dst
''')
    original_input = rx.procedure(before, "sm_handle_eapol_input")
    before = before.replace(original_input, original_input.replace(
        "  inc eapolCalls", "  capturedSource = cast[ptr array[6, uint8]](sa)[]\n  inc eapolCalls", 1), 1)
    before = before.replace("  envState.secKeyPtr = addr key\n",
        "  envState.secKeyPtr = addr key\n"
        "  envState.secInfo0 = 0x11223344'u32\n"
        "  envState.secInfo1 = 0x55667788'u32\n", 1)
    # Hook globals must precede the platform procedures that refer to them.
    declarations, helpers = SUPPORT.split("proc invoke()", 1)
    insertion = before.index("proc rxuCntrlEnvView()")
    before = before[:insertion] + declarations + "\nproc invoke()\n" + before[insertion:]
    hooks = "proc invoke()" + helpers
    # setup/snapAt are fixture helpers used by prepareEapol/prepareMic.
    setup_helpers = rx.CHECKS.split("proc checkFrame(", 1)[0]
    return (before + setup_helpers +
            hooks + "\nproc rxKeyCurrent(desc, key: pointer): bool = keyValid\n" +
            marker + handler)


CASES = {
    "eapol_reuse": r'''
prepareEapol()
action = replaceFrame
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert allocations == 1 and frees == 1 and frameCopies == 0
doAssert eapolCalls == 0 and transferred == 0 and prepared == 0
doAssert sw == replacementSw and bytes == replacementBytes
''',
    "mic_reuse": r'''
prepareMic()
action = replaceFrame
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert messageSends == 0 and messageFrees == 1 and messageStorage == nil
doAssert replayCalls == 0 and transferred == 0
doAssert sw == replacementSw and bytes == replacementBytes
''',
    "mic_key_change": r'''
prepareMic()
action = proc() = keyValid = false
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert messageSends == 0 and messageFrees == 1 and messageStorage == nil
''',
    "mic_context_change": r'''
prepareMic()
action = proc() =
  envState.secInfo0 = 0xAABBCCDD'u32
  envState.secInfo1 = 0x44332211'u32
  envState.vifIdx = 1
  key.staIdx = 4
  stations[0].macAddr = [2'u8, 1, 1, 1, 1, 1]
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert messageSends == 1 and messageFrees == 0
doAssert sentMessage.bssid == [2'u8, 9, 8, 7, 6, 5]
doAssert sentMessage.pnLow == 0x11223344 and sentMessage.pnHigh == 0x55667788
doAssert sentMessage.keyId == 3 and sentMessage.vifIdx == 0
''',
    "eapol_key_change": r'''
prepareEapol()
setup(0x4208, 32, 1748, secure = true)
snapAt(32, 0x888E)
chain.next = addr extraChain
action = proc() = keyValid = false
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert allocations == 1 and frees == 1 and frameCopies == 0
doAssert eapolCalls == 0
''',
    "eapol_context_change": r'''
prepareEapol()
action = proc() = envState.sa = [0xEE'u8, 1, 2, 3, 4, 5]
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert eapolCalls == 1
doAssert capturedSource == [6'u8, 11, 12, 13, 14, 15]
''',
    "normal_and_failure": r'''
prepareEapol()
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert eapolCalls == 1 and eapolLength == 1740
doAssert allocations == 1 and frees == 1 and frameCopies == 2
for index in 0 ..< 1704: doAssert eapolBytes[index] == bytes[index + 32]
for index in 1704 ..< 1740: doAssert eapolBytes[index] == extraBytes[index - 1704]
prepareEapol()
allocationFails = true
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert eapolCalls == 0 and frees == 0
prepareMic()
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert messageSends == 1 and messageStorage == nil
prepareMic()
allocationFails = true
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert messageSends == 0 and messageFrees == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_rx_dispatch_lifetime(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
