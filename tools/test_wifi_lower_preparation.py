"""Run real lower TX preparation without publishing retired descriptors."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_sequence import CHECKS as SEQUENCE_CHECKS, program_source

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

MODELS = r"""
type
  HostTxThdEntryView = object
    magic, payloadStart, payloadEnd, flags: uint32
    next: pointer
  HostTxRateTemplateView = object
    magic, ntxConfig, bwMask, pendingCount, policyWord, rateWord: uint32
    retryRateControl0, retryRateControl1, retryRateControl2: uint32
    txPower: int32
    retryTxPowerControl0, retryTxPowerControl1, retryTxPowerControl2: uint32
  TxBufferControlView = array[60, uint8]
  PreparedLink = object
    next, txDesc: pointer
    headerLen, padLen: uint32
    userIdx: uint8
    headerThd: HostTxThdEntryView
    payloadThd: array[4, HostTxThdEntryView]
    rateTemplate: array[60, uint8]
    ackPolicyControl, retryLimitControl: uint32
    macHeader: array[512, uint8]
  Hardware = object
    secondaryDescToStatusPadding, frameLen, magic: uint32
    secondaryTxHwDescPtr, status, controlFlags, payloadStart, payloadEnd: uint32
    frameLenToRetryLimitPadding, confirmStatus, retryLimitControl, ackPolicyControl: uint32
    chainedThd: pointer
  Queue = object
    first, last: pointer
  Control = object
    pending: CoList
  TxEnv = object
    packetCounter: uint32
    ac: array[5, Control]
"""

STORAGE = r"""
  frames: array[2, HostTxDescView]
  links: array[2, PreparedLink]
  hw: array[2, Hardware]
  backup: array[5, Queue]
  txEnv: TxEnv
  templateBytes: TxBufferControlView
  invalidated: bool
  publications: int
  released: int
"""

HELPERS = r"""
proc frameIndex(d: ptr HostTxDescView): int =
  for i in 0 ..< frames.len:
    if d == addr frames[i]: return i
  doAssert false
proc hostTxInlineBufferedLink(d: ptr HostTxDescView): ptr PreparedLink = addr links[frameIndex(d)]
proc hostTxInternalLinkNodeAt(p: pointer): ptr PreparedLink = cast[ptr PreparedLink](p)
proc hostTxBufferedLinkAt(p: pointer): ptr PreparedLink = cast[ptr PreparedLink](p)
proc hostTxLinkDescAt(p: pointer): ptr PreparedLink = cast[ptr PreparedLink](p)
proc hostTxHwDescAt(p: pointer): ptr Hardware = cast[ptr Hardware](p)
proc hostTxRateTemplate(p: ptr PreparedLink): ptr HostTxRateTemplateView =
  cast[ptr HostTxRateTemplateView](addr p.rateTemplate[0])
proc hostTxLinkMacHdrPtr(p: ptr PreparedLink; offset: uint): pointer = addr p.macHeader[offset]
proc txBufferControlAt(p: pointer): ptr TxBufferControlView =
  doAssert not invalidated, "policy read after retirement"
  cast[ptr TxBufferControlView](p)
proc txBackupQueueHeadPtr(ac: uint32): ptr pointer = addr backup[ac].first
proc txBackupQueueTailPtr(ac: uint32): ptr pointer = addr backup[ac].last
proc txControlEnv(): ptr TxEnv = addr txEnv
proc txControlAc(ac: uint32): ptr Control = addr txEnv.ac[ac]
proc captureDhcpTxRateRaw(p: ptr HostTxRateTemplateView) = discard
proc txl_frame_release(p: pointer; callback: bool) =
  doAssert not callback
  inc released
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-NIMFW] txl_push_eapol ": visit("lower")
  elif s == "[WIFI-NIMFW] txbuf_eapol ": visit("buffer_trace")
proc nimFwConnectTraceBytes(s: string; p: pointer; n, limit: uint32) = discard
proc co_list_push_back(q: ptr CoList; p: ptr CoListHdr) =
  doAssert not interrupts
  p.next = nil
  if q.last == nil: q.first = p
  else: q.last.next = p
  q.last = p
proc td_pck_ind(vif, sta: uint8; direction: uint32) =
  doAssert not invalidated, "retired preparation reached traffic accounting"
  visit("traffic")
proc ps_check_tx_frame(sta, tid: uint8): bool =
  doAssert not invalidated, "retired preparation reached PS accounting"
  visit("ps")
  false
proc txl_payload_handle_backup(p: pointer) =
  doAssert not invalidated and not interrupts
  doAssert p == nil
  inc publications
  doAssert backup[3].first == (addr links[1]) and backup[3].last == (addr links[0])
  doAssert links[1].next == addr links[0]
  doAssert txEnv.ac[3].pending.first == addr frames[1].link
  doAssert txEnv.ac[3].pending.last == addr frames[0].link
  doAssert txEnv.packetCounter == 2
"""

CHECKS = r"""
var
  afterVifs: typeof(vifs)
  afterStations: typeof(sta_info_tab)
  fired: bool
  keyValue: uint32
  keys: KeyList
keys.pairwiseKey = addr keyValue
for protocol in [0x8E88'u16, 0x0008'u16]:
  for phase in ["lower", "append", "frame_trace", "copy", "buffer_trace", "header", "traffic", "ps"]:
    if protocol == 0x8E88 and phase == "header": continue
    if protocol == 0x0008 and phase in ["lower", "frame_trace"]: continue
    for change in 0 .. 2: # target VIF, target station, unrelated VIF
      reset()
      invalidated = false
      publications = 0
      fired = false
      frames = default(typeof(frames))
      links = default(typeof(links))
      hw = default(typeof(hw))
      txEnv = default(TxEnv)
      backup = default(typeof(backup))
      frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
        hdrLen: 34, frameLen: protocol, seqPassthrough: 100,
        hwDesc: addr hw[0], queueFirst: cast[pointer](1), policy: addr templateBytes)
      frames[0].bufferPtrs[0] = 0x20000000
      frames[0].bufferLens[0] = 100
      staInfoForIdx(0).keyMat = addr keys
      backup[3] = Queue(first: addr links[1], last: addr links[1])
      txEnv.ac[3].pending = CoList(first: addr frames[1].link, last: addr frames[1].link)
      txEnv.packetCounter = 1
      calls.setLen(0)
      onStage = proc(stage: string) =
        if stage != phase: return
        fired = true
        onStage = nil
        # No preparation callback may observe the new descriptor in any queue.
        doAssert backup[3].first == (addr links[1]) and backup[3].last == (addr links[1])
        doAssert links[1].next == nil
        doAssert txEnv.ac[3].pending.first == addr frames[1].link
        doAssert txEnv.ac[3].pending.last == addr frames[1].link
        case change
        of 0: inc rxVifEpochs[1]
        of 1: inc stationEpochs[0]
        else: inc rxVifEpochs[0]
        invalidated = change != 2
        vifs[1].psFlags = 0xA5
        afterVifs = vifs
        afterStations = sta_info_tab
      discard txl_cntrl_push(addr frames[0], 3)
      doAssert fired and interrupts
      if change != 2:
        doAssert publications == 0
        doAssert backup[3].first == (addr links[1]) and backup[3].last == (addr links[1])
        doAssert links[1].next == nil
        doAssert txEnv.ac[3].pending.first == addr frames[1].link
        doAssert txEnv.ac[3].pending.last == addr frames[1].link
        doAssert txEnv.packetCounter == 2 # existing TX plus one cancellation confirmation
        doAssert droppedStatus == 0xC0020000'u32
        doAssert frames[0].bufDesc == nil and frames[0].staInfoIdx == 255
        doAssert vifs == afterVifs and sta_info_tab == afterStations
      else:
        doAssert publications == 1

# The exported allocation API retains its successful enqueue contract.
reset()
invalidated = false
frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
  hdrLen: 34, frameLen: 0x8E88, policy: addr templateBytes)
backup = default(typeof(backup))
let prepared = txl_buffer_alloc(addr frames[0], 2, 0)
doAssert prepared == addr links[0]
doAssert backup[2].first == prepared and backup[2].last == prepared
doAssert links[0].txDesc == (addr frames[0]) and interrupts

# A missing policy is an allocation failure, never a null memcpy or publication.
frames[0].policy = nil
backup = default(typeof(backup))
doAssert txl_buffer_alloc(addr frames[0], 2, 0) == nil
doAssert backup[2].first == nil and interrupts

# The no-host-marker route returns an internal lease, not a host confirmation.
for phase in ["lower", "traffic", "ps"]:
  reset()
  invalidated = false
  released = 0
  publications = 0
  frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
    hdrLen: 24, frameLen: 0x8E88, bufDesc: addr links[0], hwDesc: addr hw[0])
  backup = default(typeof(backup))
  txEnv = default(TxEnv)
  onStage = proc(stage: string) =
    if stage != phase: return
    onStage = nil
    inc rxVifEpochs[1]
    invalidated = true
  discard txl_cntrl_push(addr frames[0], 3)
  doAssert released == 1 and publications == 0
  doAssert txEnv.packetCounter == 0 and backup[3].first == nil
  doAssert interrupts

# The non-traced IPv6 path relies on the final check after the policy copy.
for scenario in 0 .. 1:
  reset()
  invalidated = false
  fired = false
  let phase = if scenario == 0: "buffer_trace" else: "copy"
  frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
    hdrLen: 34, frameLen: (if scenario == 0: 0x8E88'u16 else: 0xDD86'u16),
    policy: addr templateBytes)
  backup = default(typeof(backup))
  onStage = proc(stage: string) =
    if stage != phase: return
    onStage = nil
    fired = true
    inc rxVifEpochs[1]
    invalidated = true
  doAssert txl_buffer_alloc(addr frames[0], 2, 0) == nil,
    "standalone allocator published a retired descriptor"
  doAssert fired and invalidated
  doAssert backup[2].first == nil and interrupts

# Invalid direct entry points must not touch a buffer or a queue.
reset()
invalidated = false
txEnv = default(TxEnv)
backup = default(typeof(backup))
discard txl_cntrl_push(nil, 0)
doAssert txEnv.packetCounter == 0 and backup[0].first == nil
for vif in [0'u8, 2, 255]:
  for station in [7'u8, 255]:
    frames[0] = HostTxDescView(vifIdx: vif, staInfoIdx: station,
      frameLen: 0x8E88, hdrLen: 34, policy: addr templateBytes)
    let before = links[0]
    txu_cntrl_frame_build(addr frames[0], addr links[0].macHeader[128])
    doAssert links[0] == before
    doAssert txl_buffer_alloc(addr frames[0], 2, 0) == nil
    doAssert links[0] == before and backup[2].first == nil
"""


def build_program() -> str:
    source = "type\n  CoListHdr = object\n    next: ptr CoListHdr\n  CoList = object\n    first, last: ptr CoListHdr\n" + program_source()
    source = source.replace("  HostTxDescView = object\n", "  HostTxDescView = object\n    link: CoListHdr\n")
    source = source.replace("var\n  sta_info_tab:", MODELS + "\nvar\n  sta_info_tab:")
    source = source.replace("  retiringVif: int = -1\n", "  retiringVif: int = -1\n" + STORAGE)
    source = source.replace("proc hostTxDescAt", HELPERS + "\nproc hostTxDescAt", 1)
    source = source.replace("proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]",
        'proc vifChannelForIdx(i: uint8): ptr Vif =\n  doAssert not invalidated, "retired VIF read"\n  addr vifs[i]')
    source = source.replace("proc vifKeyPointers(v: ptr Vif): ptr tuple[flags: uint32] = addr v.keys",
        'proc vifKeyPointers(v: ptr Vif): ptr tuple[flags: uint32] =\n  doAssert not invalidated, "retired VIF key read"\n  addr v.keys')
    # The fixture's DMA address names a modeled 100-byte payload, not host RAM.
    source = source.replace("  copyMem(dst, src, size.int)\n  dst", """  if cast[uint](src) == 0x20000000'u:
    doAssert size <= 100
    zeroMem(dst, size.int)
  else:
    copyMem(dst, src, size.int)
  if size == 60: visit("copy")
  dst""")
    start = source.index("proc nimFwConnectTrace2U32")
    end = source.index("proc txl_cntrl_tx_check", start)
    source = source[:start] + r'''
proc nimFwConnectTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-CT] tx_eapol_fc ": visit("frame_trace")
  elif s in ["[WIFI-CT] txbuf_eapol ", "[WIFI-CT] txbuf_data "]: visit("buffer_trace")
  elif s == "[WIFI-CT] txthd_data ": visit("header")
''' + source[end:]
    old = procedure(source, "txl_cntrl_push")
    source = source.replace(old, "proc txl_cntrl_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.}\n")
    source = source.replace('proc txl_cntrl_inc_pck_cnt(ac: uint8) = calls.add("drop-count")',
        'proc txl_cntrl_inc_pck_cnt(ac: uint8) =\n  inc txEnv.packetCounter\n  calls.add("drop-count")')
    source = source.replace("  start\n", '  visit("append")\n  start\n')
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in ["txlApplyEapolRetryPolicy", "txlApplyBootstrapDataRetryPolicy",
        "txlEnqueuePrepared", "txlPrepareBuffer", "txl_buffer_alloc", "txlBuildBufferThd",
        "txl_buffer_update_thd", "txl_cntrl_push"])
    names = set(re.findall(r"\bnimFwDbg\w+", functions))
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(names) if f"  {name}:" not in source)
    return source + debug + functions + SEQUENCE_CHECKS.split("proc checkTx(", 1)[0] + CHECKS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "lower_trace", "lower_header", "lower_traffic", "lower_ps",
                                      "prepare_after_frame", "prepare_final", "frame_after_append", "frame_after_trace", "eager_queue",
                                      "lower_header_pair", "prepare_after_frame_pair", "frame_after_trace_pair"])
def test_lower_preparation(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = tmp_path / "lower_preparation.nim"
    program = build_program()
    if mutation is not None:
        fault = mutation.removesuffix("_pair")
        name = ("txl_cntrl_push" if fault.startswith("lower_") else
                "txlPrepareBuffer" if fault.startswith("prepare_") or fault == "eager_queue"
                else "txuBuildFrame")
        owner = "tx_upper.nim" if name == "txuBuildFrame" else "tx_layer.nim"
        body = procedure((FW / owner).read_text(), name)
        assert program.count(body) == 1
        changed = body
        if fault.startswith("lower_"):
            index = {"lower_trace": 1, "lower_header": 3, "lower_traffic": 4, "lower_ps": 5}[fault]
            line = "  ensurePreparedSession()\n" if index in [1, 4, 5] else "    ensurePreparedSession()\n"
            lines = body.splitlines(keepends=True)
            guards = [i for i, text in enumerate(lines) if text.strip() == "ensurePreparedSession()"]
            assert len(guards) == 6 and lines[guards[index]] == line
            del lines[guards[index]]
            changed = "".join(lines)
        elif fault == "eager_queue":
            line = "  let bufLink = hostTxInlineBufferedLink(desc)\n"
            assert body.count(line) == 1
            changed = body.replace(line, line + "  txlEnqueuePrepared(param, cast[pointer](bufLink), queueIdx)\n")
        elif fault == "prepare_after_frame":
            changed = body.replace("if not txlSessionCurrent(identity, desc) or desc.policy == nil:", "if desc.policy == nil:")
        else:
            variable = "desc" if fault == "prepare_final" else "txDesc"
            result = "nil" if fault == "prepare_final" else "false"
            condition = f"not txlSessionCurrent(identity, {variable})"
            if fault == "prepare_final": condition += " or not txSecurityCurrent(desc)"
            guard = f"  if {condition}:\n    return{(' ' + result) if result else ''}\n"
            assert body.count(guard) == (1 if fault == "prepare_final" else 2)
            index = body.rfind(guard) if fault in ["prepare_final", "frame_after_trace"] else body.find(guard)
            changed = body[:index] + body[index + len(guard):]
        assert changed != body
        program = program.replace(body, changed)
        if mutation.endswith("_pair"):
            callee = "txlBuildBufferThd" if fault == "lower_header" else "txuBuildFrame"
            callee_body = procedure(program, callee)
            if fault == "lower_header":
                guard = "      ensureCurrentThd()\n"
                assert callee_body.count(guard) == 4
                changed_callee = callee_body.replace(guard, "")
            elif fault == "frame_after_trace":
                guard = "      ensureCurrentBuild()\n"
                assert callee_body.count(guard) == 5
                changed_callee = "".join(callee_body.rsplit(guard, 1))
                # Retire at the last trace to exercise both adjacent guards.
                first = 'if s == "[WIFI-CT] tx_eapol_fc ": visit("frame_trace")'
                last = 'if s == "[WIFI-CT] tx_eapol_snap ": visit("frame_trace")'
                assert program.count(first) == 1
                program = program.replace(first, last, 1)
            else:
                guard = "  if not txlSessionCurrent(identity, txDesc):\n    return false\n"
                assert callee_body.count(guard) == 2
                changed_callee = callee_body.replace(guard, "", 1)
            program = program.replace(callee_body, changed_callee, 1)
    source.write_text(program)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiConnectTrace", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    # Another ownership check covers each of these guards. Paired removals
    # above must still be detected by the fixture.
    redundant_guards = {"lower_header", "prepare_after_frame", "frame_after_trace"}
    if mutation is None or mutation in redundant_guards:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
        if mutation == "prepare_final":
            assert "standalone allocator published a retired descriptor" in result.stdout
