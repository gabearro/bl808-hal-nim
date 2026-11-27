"""Check RX slot generations across upload callbacks and reset/recycling."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import RX_RING_CONFIG_IMPORT
from test_wifi_rx_upload import PLATFORM as BASE

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
var
  uploadHook, enterHook: proc()
  irq = true
  releaseIrqs: seq[bool]
proc rxInvalidateUpload(desc: pointer)
proc irqSave(): uint32 =
  result = irq.uint32 * 8
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
''' + BASE.replace(
    "proc rxUploadGeneration(p: pointer): uint32 = 0\n", ""
).replace(
    "proc rxUploadCurrent(p: pointer; generation: uint32): bool = true\n", ""
).replace(
    "proc rxReleaseUpload(node: pointer; generation: uint32) = rxl_mpdu_free(node)\n", ""
).replace(
    "proc rxl_mpdu_free(node: pointer) =\n",
    "proc rxl_mpdu_free(node: pointer) =\n"
    "  releaseIrqs.add(irq)\n"
    "  rxInvalidateUpload(node)\n",
).replace(
    "  inputResult\n", "  if uploadHook != nil: uploadHook()\n  inputResult\n"
).replace(
    '  calls.add("enter")\n', '  calls.add("enter")\n  if enterHook != nil: enterHook()\n'
) + r'''
type Pair = object
  firstHeaderDesc: pointer
type RxStationIdentity = uint32
var
  slots: array[2, RxMpduDescView]
  headers: array[2, RxSwDescView]
  payloads: array[2, RxPayloadHwDescView]
  pairs: array[41, Pair]
  rxUploadEpochs: array[41, uint32]
  rxInitializationEpoch: uint32
  rxStationIdentities: array[41, uint32]
proc rxMpduDescIndex(p: pointer): int =
  for i in 0 ..< slots.len:
    if p == cast[pointer](addr slots[i]): return i
  -1
proc rxHeaderDescIndex(p: pointer): int =
  for i in 0 ..< headers.len:
    if p == cast[pointer](addr headers[i]): return i
  -1
proc rxSwTableDescAt(i: int): ptr Pair = addr pairs[i]
proc rxHeaderHwDescAt(i: int): pointer = cast[pointer]((i + 1).uint)
'''

CHECKS = r'''
proc setup(raw = true) =
  slots = default(typeof(slots))
  headers = default(typeof(headers))
  payloads = default(typeof(payloads))
  upper = default(RxuEnv)
  lower = default(RxlEnv)
  calls.setLen(0)
  freed.setLen(0)
  releaseIrqs.setLen(0)
  uploadHook = nil
  enterHook = nil
  inputResult = 0
  irq = true
  for i in 0 .. 1:
    payloads[i].bufferAddr = (0x20000000 + i * 0x1000).uint32
    headers[i].bufferChain = addr payloads[i]
    headers[i].mpduLengthBytes = 20
    headers[i].frameControlFlags = if raw: 2 else: 0
    slots[i].swDesc = addr headers[i]
    slots[i].descFlag = 3

# Generation changes, not just station/VIF identity, distinguish slot reuse.
setup()
let initial = rxUploadGeneration(addr slots[0])
rx_swdesc_init()
doAssert not rxUploadCurrent(addr slots[0], initial)
let initialized = rxUploadGeneration(addr slots[0])
rxForgetStation(addr headers[0])
doAssert not rxUploadCurrent(addr slots[0], initialized)
let captured = rxUploadGeneration(addr slots[0])
rxInvalidateUpload(addr slots[0])
doAssert not rxUploadCurrent(addr slots[0], captured)
rxReleaseUpload(addr slots[0], captured)
doAssert freed.len == 0
doAssert not rxUploadCurrent(nil, 0) and not rxUploadCurrent(cast[pointer](1), 0)
rxUploadEpochs[0] = high(uint32)
rxInvalidateUpload(addr slots[0])
doAssert rxUploadGeneration(addr slots[0]) == 0

# Raw copies are recycled in every build, and check/free runs with IRQs masked.
setup()
upper.uploadList.nodes.add(addr slots[0])
rxu_swdesc_upload_evt()
doAssert freed == @[cast[pointer](addr slots[0])] and releaseIrqs == @[false]
doAssert lower.uploadCount == 0 and irq

for failure in [false, true]:
  for incomingIrq in [false, true]:
    setup()
    irq = incomingIrq
    inputResult = if failure: -1 else: 0
    upper.uploadList.nodes.add(addr slots[0])
    uploadHook = proc() =
      rxInvalidateUpload(addr slots[0])
      headers[0].mpduLengthBytes = 555
      payloads[0].usedFlag = 0xA5A5
      lower.uploadCount = 777
      nimFwDbgRxuUploadTcpipOk = 123
      nimFwDbgRxuUploadTcpipFail = 456
    rxu_swdesc_upload_evt()
    doAssert irq == incomingIrq
    doAssert freed.len == 0 and releaseIrqs.len == 0
    doAssert headers[0].mpduLengthBytes == 555 and payloads[0].usedFlag == 0xA5A5
    doAssert lower.uploadCount == 777
    doAssert nimFwDbgRxuUploadTcpipOk == 123 and nimFwDbgRxuUploadTcpipFail == 456

when not defined(bl808WifiRxPbufInput):
  setup(false)
  upper.uploadList.nodes.add(addr slots[0])
  enterHook = proc() =
    rxInvalidateUpload(addr slots[0])
    lower.uploadCount = 777
  rxu_swdesc_upload_evt()
  doAssert freed.len == 0 and lower.uploadCount == 777
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("pbuf_input", [False, True])
@pytest.mark.parametrize("mutation", [None, "lease", "release", "init", "forget", "invalidate"])
def test_rx_upload_slot_lifetime(tmp_path: Path, mode: str, pbuf_input: bool, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    lower = (FW / "rx_layer.nim").read_text()
    upper = procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    names = ["rx_swdesc_init", "rxForgetStation", "rxUploadGeneration", "rxUploadCurrent",
             "rxInvalidateUpload", "rxReleaseUpload"]
    parts = {name: procedure(lower, name) for name in names}
    if mutation == "lease":
        old = "    if not current():"
        assert upper.count(old) == 1
        upper = upper.replace(old, "    if false:")
    elif mutation == "release":
        parts["rxReleaseUpload"] = parts["rxReleaseUpload"].replace(
            "if rxUploadCurrent(desc, generation):", "if true:")
    elif mutation == "init":
        parts["rx_swdesc_init"] = parts["rx_swdesc_init"].replace("    inc rxUploadEpochs[rxSwTableIndex]\n", "")
    elif mutation == "forget":
        parts["rxForgetStation"] = parts["rxForgetStation"].replace("    inc rxUploadEpochs[index]\n", "")
    elif mutation == "invalidate":
        parts["rxInvalidateUpload"] = parts["rxInvalidateUpload"].replace("    inc rxUploadEpochs[index]", "    discard")
    path = tmp_path / "upload_lifetime.nim"
    path.write_text(RX_RING_CONFIG_IMPORT + PLATFORM + "".join(parts.values()) + upper + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    if pbuf_input:
        options[mode].append("-d:bl808WifiRxPbufInput")
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(path)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "AddressSanitizer", "SIGSEGV", "SIGBUS"]), result.stdout
