"""Execute production RX duplicate filters and cache initialization on the host.

The extracted overlay has no native pointers, so its byte offsets are identical
on the host and target. Other station fields and RX diagnostics are test doubles.
"""

from pathlib import Path
import shutil
import subprocess
import textwrap

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const STA_ENTRY_SIZE = 368
const StationCount = 7
type
  StaInfoView {.packed.} = object
    prefix: array[24, uint8]
    initialRateConfig: uint32
    middle: array[304, uint8]
    supportedRatesBitmap: uint16
    tail: array[34, uint8]
  RxEnv = object
    seqCtrl: uint16
    tid, machdrLen: uint8
  RxDesc = object
    mpduLengthBytes: uint16
var
  sta_info_tab: array[StationCount * STA_ENTRY_SIZE + 64, uint8]
  nimFwDbgRxuDropDup, nimFwDbgRxuDropDupFc, nimFwDbgRxuDropDupSeq: uint32

proc nimFwDbgRecordRxuDupDrop(frame: pointer; flags: uint32;
                             seqCtrl: uint16; tid, headerLen: uint8;
                             cachedSeq, frameLen: uint16) = discard
template doReturn() = return true
"""

CHECKS = r"""
static:
  doAssert sizeof(StaInfoView) == STA_ENTRY_SIZE
  doAssert offsetof(StaInfoView, supportedRatesBitmap) == 332
  doAssert offsetof(StaRxSequenceOverlay, nonQosSeqCtrl) == 336
  doAssert offsetof(StaRxSequenceOverlay, qosSeqCtrl) == 338
  doAssert sizeof(StaRxSequenceOverlay) == 356

# Registration must only change the rate-config word and this STA's caches.
# In particular, the old four-byte stride overwrote the following STA's link.
for station in 0 ..< StationCount:
  for b in sta_info_tab.mitems: b = 0xA5
  var expected = sta_info_tab
  let base = station * STA_ENTRY_SIZE
  expected[base + 24] = 0
  expected[base + 25] = 0x90
  expected[base + 26] = 1
  expected[base + 27] = 0
  for i in 336 ..< 356: expected[base + i] = 0xFF
  initCaches(staInfoForIdx(station.uint8))
  doAssert sta_info_tab == expected, "registration wrote outside RX caches"
  doAssert staInfoForIdx(station.uint8).supportedRatesBitmap == 0xA5A5
  for tid in 0'u8 .. 8'u8:
    let cache = rxuQosSeqCachePtr(staInfoForIdx(station.uint8), tid)
    doAssert cast[uint](cache) - cast[uint](addr sta_info_tab[0]) ==
      (base + 338 + tid.int * 2).uint
    doAssert cache[] == 0xFFFF

for b in sta_info_tab.mitems: b = 0xA5
for station in 0 ..< StationCount:
  initCaches(staInfoForIdx(station.uint8))

# Independent model: one non-QoS/management cache and eight QoS TID caches
# per station. It deliberately does not use the production layout helpers.
var model: array[StationCount, array[9, uint16]]
for cache in model.mitems:
  for value in cache.mitems: value = 0xFFFF

proc receive(station: int; fc, sequence: uint16; tid: uint8; management: bool) =
  let qos = not management and (fc and 0x80) != 0
  let slot = if qos: tid.int else: 8
  let expectedDrop = (fc and 0x0800) != 0 and model[station][slot] == sequence
  let before = sta_info_tab
  let dropped = if management:
      managementIsDuplicate(station.uint8, fc, sequence)
    else:
      dataIsDuplicate(station.uint8, fc, sequence, tid)
  doAssert dropped == expectedDrop, "Retry-bit duplicate decision"
  var expected = before
  if not expectedDrop:
    model[station][slot] = sequence
    let offset = station * STA_ENTRY_SIZE + (if qos: 338 + 2 * tid.int else: 336)
    expected[offset] = (sequence and 0xFF).uint8
    expected[offset + 1] = (sequence shr 8).uint8
  doAssert sta_info_tab == expected, "RX changed another cache or station field"

# Sequence zero and wraparound are valid even if they match the cached value
# when Retry is clear; only a matching retransmission should be discarded.
for station in 0 ..< StationCount:
  for baseFc in [0x0008'u16, 0x0208'u16, 0x0088'u16, 0x0288'u16,
                 0x0000'u16, 0x0080'u16, 0x00B0'u16]:
    let management = (baseFc and 0x0C) == 0
    for tid in 0'u8 .. 7'u8:
      for sequence in [0'u16, 0x0010, 0xFFF0, 0xFFFF, 0, 0]:
        receive(station, baseFc, sequence, tid, management)
        receive(station, baseFc or 0x0800, sequence, tid, management)
        receive(station, baseFc, sequence, tid, management)

# Interleave stations and TIDs, with unrelated FC flags and fragment numbers.
var rng = 0x351A9D4'u32
for event in 0 ..< 5000:
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 17)
  rng = rng xor (rng shl 5)
  let station = (rng mod StationCount.uint32).int
  let tid = ((rng shr 8) and 7).uint8
  let management = (rng and 0x10) != 0
  let baseFc = if management: 0x00B0'u16
    elif (rng and 0x20) != 0: 0x0288'u16
    else: 0x0208'u16
  let slot = if not management and (baseFc and 0x80) != 0: tid.int else: 8
  let sequence = if (rng and 0x40) != 0: model[station][slot]
    else: (rng shr 16).uint16
  let fc = baseFc or (rng.uint16 and 0xFC00'u16)
  receive(station, fc, sequence, tid, management)
"""


def test_rx_sequence_cache_and_retry_filter(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    base = ROOT / "src/bl808/wifi/fw"
    layout = (base / "layout_types.nim").read_text()
    rx = (base / "rx_upper.nim").read_text()
    tasks = (base / "task_handlers.nim").read_text()
    sta = (base / "sta_management.nim").read_text()

    overlay = "  StaRxSequenceOverlay" + layout.split(
        "  StaRxSequenceOverlay", 1
    )[1].split("\n  ApSelfStaStartOverlay", 1)[0]
    station_helpers = "template staInfoAt(p: pointer)" + layout.split(
        "template staInfoAt(p: pointer)", 1
    )[1].split("\ntemplate staConnectionStartWord", 1)[0]
    sequence_helper = "template staRxSequence" + layout.split(
        "template staRxSequence", 1
    )[1].split("\ntemplate ", 1)[0]
    qos_helper = "proc rxuQosSeqCachePtr" + rx.split(
        "proc rxuQosSeqCachePtr", 1
    )[1].split("\nproc ", 1)[0]
    init = sta.split("  # Initial rate config\n", 1)[1].split(
        "  # Store TX policy descriptor pointer", 1
    )[0]
    data = rx.split("        # Sequence/reorder context\n", 1)[1].split(
        "        # .L171: EAPOL detection", 1
    )[0]
    # Model a frame that passed the intervening integrity checks. Rejected
    # frames must not commit this cache; the dispatcher tests cover that path.
    data += next("        " + line.strip() + "\n" for line in rx.splitlines()
                 if line.strip() == "seqCachePtr[] = envSeq")
    management = rx.split(
        "        # frameTypeBits == 0: Management in associated path\n", 1
    )[1].split("\n        # Commit pairwise replay state", 1)[0]
    # This isolated model represents a frame that passed session/replay checks.
    management += next("        " + line.strip() + "\n" for line in tasks.splitlines()
                       if line.strip() == "rxSeq.nonQosSeqCtrl = envSeq")

    wrappers = "\nproc initCaches(sta: ptr StaInfoView) =\n" + init
    wrappers += """
proc dataIsDuplicate(station: uint8; frameControl, sequence: uint16;
                     tid: uint8): bool =
  let sta = staInfoForIdx(station)
  var state = RxEnv(seqCtrl: sequence, tid: tid, machdrLen: 26)
  let env = addr state
  var desc = RxDesc(mpduLengthBytes: 100)
  let swdesc = addr desc
  let frame: pointer = nil
  let hwFlags = 0'u32
"""
    wrappers += textwrap.indent(textwrap.dedent(data), "  ") + "  return false\n"
    wrappers += """
proc managementIsDuplicate(station: uint8; frameControl, sequence: uint16): bool =
  let sta = staInfoForIdx(station)
  var state = RxEnv(seqCtrl: sequence)
  let env = addr state
"""
    wrappers += textwrap.indent(textwrap.dedent(management), "  ")
    wrappers += "\n  return false\n"
    source = tmp_path / "rx_sequence_test.nim"
    source.write_text(PLATFORM + "\ntype\n" + overlay + "\n" + station_helpers
                      + "\n" + sequence_helper + "\n" + qos_helper
                      + wrappers + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
         "--skipUserCfg:on", "--checks:on",
         f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'rx_sequence_test'}",
         str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
