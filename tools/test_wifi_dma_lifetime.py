"""Interrupt active TX backup processing at every modeled callout."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_ownership import DMA_INVALIDATION_STUBS
from test_wifi_tx_backup import PLATFORM as BACKUP_PLATFORM, CHECKS as BACKUP_CHECKS
from test_wifi_vif_tx_drain import PLATFORM as VIF_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = BACKUP_PLATFORM.replace(DMA_INVALIDATION_STUBS, "").replace(
    "    queueFirst, bufDesc, hwDesc, callback: pointer",
    "    queueFirst, bufDesc, hwDesc, callback, callbackArg, cfmDst: pointer\n"
    "    usedFlag: uint8\n    active: uint32",
).replace(
    "  TxDmaOwner = object", "  Head = object\n    flags: uint32\n    confirmType: uint16\n"
    "  TxFrameEnvView = object\n    freeList, usedList: CoList\n  TxDmaOwner = object",
).replace(
    "  txActiveDmaOwner: ptr TxDmaOwner",
    "  frameEnv: TxFrameEnvView\n  confirmHeads: array[3, Head]\n"
    "  confirmLists: array[5, CoList]\n"
    "  outputs: array[3, uint32]\n  txActiveDmaOwner: ptr TxDmaOwner",
)


def instrument_platform() -> str:
    source = PLATFORM
    source = source.replace(procedure(source, "txl_frame_release"), "")
    source = source.replace("proc pointerAddrU32", "proc observe(label: string)\nproc pointerAddrU32", 1)
    replacements = {
        "nimFwMgmtFcTrace": "proc nimFwMgmtFcTrace(fc: uint8): bool = (fc and 12) == 0\n",
        "nimFwTrace2U32": "proc nimFwTrace2U32(s: string; a, b: uint32) = observe(s)\n",
        "nimFwConnectTrace2U32": "proc nimFwConnectTrace2U32(s: string; a, b: uint32) = observe(s)\n",
        "nimFwConnectTraceBytes": "proc nimFwConnectTraceBytes(s: string; p: pointer; length, limit: uint32) = observe(s)\n",
        "nimFwDbgDhcpTxFinalBreakpoint": "proc nimFwDbgDhcpTxFinalBreakpoint() = observe(\"breakpoint\")\n",
        "captureDhcpTxRateRaw": "proc captureDhcpTxRateRaw(p: ptr HostTxRateTemplateView) = observe(\"capture\")\n",
        "macAddrWord0": "proc macAddrWord0(p: ptr array[6, uint8]): uint32 =\n  observe(\"macword\")\n  0\n",
        "c_memcpy": "proc c_memcpy(dst, src: pointer; n: uint32): pointer =\n  copyMem(dst, src, n.int)\n  observe(\"copy\")\n  dst\n",
        "txl_machdr_format": "proc txl_machdr_format(p: pointer) =\n  observe(\"format\")\n",
        "txu_cntrl_tkip_mic_append": "proc txu_cntrl_tkip_mic_append(p: pointer) =\n  observe(\"mic\")\n",
        "regRead": "proc regRead(address: uint): uint32 =\n  result = timerBase\n  observe(\"timer-read\")\n",
        "machwTxDmaStatus": "proc machwTxDmaStatus(): uint32 =\n  result = dmaStatus\n  observe(\"dma-status\")\n",
        "machwTxStatus": "proc machwTxStatus(): uint32 =\n  observe(\"status\")\n  0\n",
        "machwTxAggActive": "proc machwTxAggActive(): uint32 =\n  result = aggActive\n  observe(\"active\")\n",
        "machwTxAggSet": "proc machwTxAggSet(mask: uint32) =\n  doAssert not txActiveDmaOwner.cancelled\n  aggSet = aggSet or mask\n  observe(\"agg-set\")\n",
        "machwTxAggActiveSet": "proc machwTxAggActiveSet(mask: uint32) =\n  doAssert not txActiveDmaOwner.cancelled\n  aggActive = mask\n  observe(\"active-set\")\n",
        "machwTxSetHead": "proc machwTxSetHead(ac: uint32; head: pointer) =\n  doAssert not txActiveDmaOwner.cancelled\n  heads[ac] = head\n  observe(\"head-set\")\n",
        "machwTxHeadValue": "proc machwTxHeadValue(ac: uint32): uint32 =\n  result = pointerAddrU32(heads[ac])\n  observe(\"head-read\")\n",
        "machwTxTrigger": "proc machwTxTrigger(mask: uint32) =\n  doAssert not txActiveDmaOwner.cancelled\n  triggers.add(mask)\n  observe(\"trigger\")\n",
        "blmac_abs_timer_set": "proc blmac_abs_timer_set(ac, deadline: uint32) =\n  doAssert not txActiveDmaOwner.cancelled\n  timers.add((ac, deadline))\n  observe(\"timer-set\")\n",
        "assert_rec": "proc assert_rec(file, text: cstring; line: cint) =\n  observe(\"assert\")\n",
        "hostTxHwDescAt": "proc hostTxHwDescAt(p: pointer): ptr HostTxHwDescView =\n  doAssert p != cast[pointer](1), \"retired hardware pointer read\"\n  cast[ptr HostTxHwDescView](p)\n",
        "hostTxLinkDescAt": "proc hostTxLinkDescAt(p: pointer): ptr HostTxLinkDescView =\n  doAssert p != cast[pointer](1), \"retired buffer pointer read\"\n  cast[ptr HostTxLinkDescView](p)\n",
        "vifChannelForIdx": "proc vifChannelForIdx(vif: uint8): ptr Vif =\n  doAssert vif < 2, \"retired VIF index read\"\n  addr vifs[vif]\n",
    }
    for name, body in replacements.items():
        old = procedure(source, name)
        assert old
        source = source.replace(old, body, 1)
    source += r"""
proc rfPriApplyWb03AuthTxLatches() = observe("rf")
proc txl_frame_desc_valid(p: pointer): bool = p == cast[pointer](addr descs[0])
proc txlCaptureFrameCallback(d: ptr HostTxDescView): int = 0
proc txlInvokeFrameCallback(cb, arg: pointer; status: uint32; context: int) = discard
proc txlFrameEndLease(d: ptr HostTxDescView) = discard
proc txFrameEnv(): ptr TxFrameEnvView = addr frameEnv
proc hostTxHeadThd(h: ptr HostTxHwDescView): ptr Head =
  for i in 0 ..< hw.len:
    if h == addr hw[i]: return addr confirmHeads[i]
  doAssert false
proc hostTxThdConfirmAt(h: ptr Head): ptr Head = h
proc hostTxConfirmLinkWord(d: ptr HostTxDescView): ptr uint32 = addr d.active
const txl_cfm_evt_bit = [0x4000'u32, 0x8000, 0x10000, 0x20000, 0x40000]
proc txCfmList(ac: uint32): ptr CoList = addr confirmLists[ac]
proc ke_evt_set(bits: uint32) = discard
proc noteMgmtTxConfirm(d: ptr HostTxDescView; status, phase: uint32) = discard
"""
    return source

CHECKS = r"""
var
  step, stopAt, action: int
  fired: bool
  replacementAc, originalAc: int
  replacementSlot: int

proc makeReplacement() =
  let slot = replacementSlot
  links[slot] = default(HostTxLinkDescView)
  hw[slot] = default(HostTxHwDescView)
  hwLinks[slot] = default(HostTxThdEntryView)
  descs[slot] = HostTxDescView(bufDesc: addr links[slot], hwDesc: addr hw[slot],
    vifIdx: 0, staInfoIdx: 4, staIdx: 0, frameLen: 0x0608, usedFlag: 1,
    cfmDst: addr outputs[slot])
  links[slot].txDesc = addr descs[slot]
  links[slot].macHeader[0] = 0x88
  queues[replacementAc] = BackupQueue(first: addr links[slot], last: addr links[slot])

proc observe(label: string) =
  doAssert not interruptsEnabled and txActiveDmaOwner != nil
  inc step
  if fired or stopAt <= 0 or step != stopAt: return
  fired = true
  let owner = txActiveDmaOwner
  doAssert owner.desc == addr descs[0]
  if action == 7:
    makeReplacement()
    txl_payload_handle_backup(nil)
    doAssert txActiveDmaOwner == owner and not owner.cancelled
    doAssert controls[replacementAc].current != addr hw[replacementSlot].magic
    return
  case action
  of 0: txu_cntrl_cfm(addr descs[0])
  of 1: txl_frame_release(addr descs[0], false)
  of 2: txlInvalidateDmaAc(originalAc.uint8)
  of 3: txlInvalidateDmaVif(1)
  of 4: txlInvalidateDmaStation(3)
  of 5: txlInvalidateDmaAll()
  of 8: txl_cfm_push(addr descs[0], 0x80000000'u32, originalAc.uint32)
  else: txlInvalidateDmaPool()
  doAssert owner.cancelled, "completion or teardown did not invalidate the active owner"
  # Model retirement resetting queue state and releasing/reusing descriptor memory.
  controls = default(typeof(controls))
  queues = default(typeof(queues))
  heads = default(typeof(heads))
  triggers.setLen(0)
  timers.setLen(0)
  aggActive = 0
  aggSet = 0
  dmaStatus = 0
  descs[0].bufDesc = cast[pointer](1)
  descs[0].hwDesc = cast[pointer](1)
  descs[0].vifIdx = 255
  descs[0].staInfoIdx = 255
  makeReplacement()
  txl_payload_handle_backup(nil)
  doAssert txActiveDmaOwner == owner and owner.cancelled
  doAssert controls[replacementAc].current == nil, "nested drain consumed replacement work"

proc setup(ac, profile: int; existing: bool) =
  let payload = profile != 0
  let fc = if profile == 0: 0x40'u8 elif profile == 1: 0xB0'u8 else: 0x88'u8
  reset(ac, 1, existing, payload, 0x20, 0xA5, (if profile == 4: 255'u8 else: 0'u8))
  links[0].macHeader[0] = fc
  descs[0].vifIdx = 1
  descs[0].staInfoIdx = 3
  descs[0].usedFlag = 1
  descs[0].cfmDst = addr outputs[0]
  hw[0].frameLen = 40
  nimFwDbgEapolTraceCount = 0
  nimFwDbgCfmTraceCount = 0
  confirmLists = default(typeof(confirmLists))
  if profile == 2 or profile == 4: descs[0].frameLen = 0x8E88
  if profile == 3: descs[0].frameLen = 0x0008
  if profile == 5:
    const shifts = [4, 8, 12, 16, 0]
    dmaStatus = 2'u32 shl shifts[ac]
  step = 0
  fired = false
  txDmaRescan = false
  doAssert txActiveDmaOwner == nil

for ac in 0 .. 4:
  for profile in 0 .. 5:
    for existing in [false, true]:
      originalAc = ac
      stopAt = 0
      setup(ac, profile, existing)
      txl_payload_handle_backup(nil)
      let calls = step
      doAssert calls > 0 and interruptsEnabled and txActiveDmaOwner == nil
      for target in 1 .. calls:
        for kind in [0, 1, 2, 3, 4, 5, 6, 8]:
          for reuse in [false, true]:
            for earlier in [false, true]:
              action = kind
              replacementSlot = (if reuse: 0 else: 1)
              replacementAc = (if earlier: 0 else: ac)
              setup(ac, profile, existing)
              stopAt = target
              txl_payload_handle_backup(nil)
              doAssert fired and interruptsEnabled and txActiveDmaOwner == nil,
                "ac=" & $ac & " profile=" & $profile & " existing=" & $existing &
                " target=" & $target & " action=" & $kind & " reuse=" & $reuse &
                " earlier=" & $earlier & " step=" & $step & " fired=" & $fired &
                " irq=" & $interruptsEnabled
              doAssert queues[replacementAc].first == nil, "replacement TX was stranded"
              doAssert controls[replacementAc].current == addr hw[replacementSlot].magic
              doAssert controls[replacementAc].packetCount == 1
              doAssert triggers == @[StartMasks[replacementAc]], "retired processing resumed"
              doAssert heads[replacementAc] == addr hw[replacementSlot].magic

# An ordinary nested submission must defer without cancelling the current one.
for ac in 0 .. 4:
  for earlier in [false, true]:
    originalAc = ac
    replacementAc = (if earlier: 0 else: ac)
    replacementSlot = 1
    action = 7
    setup(ac, 1, false)
    stopAt = 1
    txl_payload_handle_backup(nil)
    doAssert fired and interruptsEnabled and txActiveDmaOwner == nil
    doAssert queues[replacementAc].first == nil
    doAssert controls[replacementAc].current == addr hw[1].magic
    if replacementAc == ac:
      doAssert controls[ac].packetCount == 9
      doAssert hwLinks[0].next == addr hw[1].magic
    else:
      doAssert controls[ac].packetCount == 8
      doAssert controls[0].packetCount == 8
      doAssert controls[ac].current == addr hw[0].magic

# Identity-specific invalidations must leave another frame/AC/VIF/station alone.
var owner = TxDmaOwner(desc: addr descs[0], vif: 1, station: 3, ac: 2)
txActiveDmaOwner = addr owner
txlInvalidateDmaFrame(addr descs[1])
txlInvalidateDmaAc(0)
txlInvalidateDmaVif(0)
txlInvalidateDmaStation(1)
doAssert not owner.cancelled
txlInvalidateDmaFrame(addr descs[0])
doAssert owner.cancelled
txActiveDmaOwner = nil
txlInvalidateDmaAll()
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "checkpoints", "notification", "rescan", "recursive", "queued_completion"])
def test_dma_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = procedure((FW / "runtime_helpers.nim").read_text(), "wifiDmaStoreLink")
    functions += "".join(procedure(tx, name) for name in [
        "txlInvalidateDmaFrame", "txlInvalidateDmaAc", "txlInvalidateDmaVif",
        "txlInvalidateDmaStation", "txlInvalidateDmaAll", "txlInvalidateDmaPool",
        "txl_payload_handle_backup", "txl_frame_release", "txl_cfm_push",
    ]) + procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    if mutation == "checkpoints":
        functions, count = re.subn(r"(?m)^\s+checkDmaOwner\(\)\n", "\n", functions)
        assert count == 83
    elif mutation == "notification":
        old = procedure(functions, "txlInvalidateDmaFrame")
        functions = functions.replace(old, "proc txlInvalidateDmaFrame(desc: pointer) = discard\n")
    elif mutation == "queued_completion":
        body = procedure(functions, "txl_cfm_push")
        changed, count = re.subn(r"(?m)^ +txlInvalidateDmaFrame\(desc\)\n", "", body)
        assert count == 1
        functions = functions.replace(body, changed)
    elif mutation in ["rescan", "recursive"]:
        old = ("  if txActiveDmaOwner != nil:\n"
               "    txDmaRescan = true\n"
               "    return\n")
        assert old in functions
        functions = functions.replace(old, "" if mutation == "recursive" else
            "  if txActiveDmaOwner != nil:\n    return\n")
    debug = "\nvar\n" + "".join(
        f"  {name}: {'array[64, uint8]' if name == 'nimFwDbgProbePayRaw' else 'uint32'}\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
        if name != "nimFwDbgDhcpTxFinalBreakpoint"
    )
    reset = BACKUP_CHECKS.split("const ResumeMasks", 1)[0]
    constants = "\nconst StartMasks = [512'u32, 1024, 2048, 4096, 256]\n"
    source = tmp_path / "dma_lifetime.nim"
    source.write_text(instrument_platform() + debug + functions + reset + constants + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiConnectTrace", "-d:bl808WifiDiagDhcpTxFinalSnapshot",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


NOTIFICATION_CHECKS = r"""
var
  frames: array[2, HostTxDescView]
  hardware: array[2, HwDesc]
  heads: array[2, HeadThd]
  outputs: array[2, uint32]

for route in 0 .. 7:
  for same in [false, true]:
    frames = default(typeof(frames))
    hardware = default(typeof(hardware))
    heads = default(typeof(heads))
    frameEnv = default(TxFrameEnvView)
    txEnv = default(TxControlEnvView)
    confirmLists = default(typeof(confirmLists))
    stations = default(typeof(stations))
    buffers = default(BufferEnv)
    hostQueue = default(CoList)
    ipc.hostTxList = addr hostQueue
    txActiveFlush = nil
    txRetiringVifMask = 0
    rxVifEpochs = default(typeof(rxVifEpochs))
    interruptsEnabled = false
    for i in 0 .. 1:
      frames[i] = HostTxDescView(hwDesc: addr hardware[i], cfmDst: addr outputs[i],
        vifIdx: 1, staInfoIdx: 2)
      hardware[i].head = addr heads[i]
    let selected = if same: 0 else: 1
    var owner = TxDmaOwner(desc: addr frames[selected], vif: (if same: 1'u8 else: 0'u8),
      station: (if same: 2'u8 else: 3'u8), ac: (if same: 2'u8 else: 0'u8))
    txActiveDmaOwner = addr owner
    case route
    of 0: txl_frame_cfm(addr frames[0])
    of 1:
      co_list_push_back(addr frameEnv.usedList, addr frames[0].link)
      txEnv.packetCounter = 1
      txl_frame_evt()
    of 2: txl_frame_release(addr frames[0], false)
    of 3: txu_cntrl_cfm(addr frames[0])
    of 4:
      var batch: TxFlushBatch
      txlDetachAc(2, 0x40000000, batch)
      txActiveFlush = batch.previous
    of 5: txl_retire_vif(1, 0)
    of 6: txl_retire_station(2, 0)
    else: txl_cfm_push(addr frames[0], 0x80000000'u32, 2)
    doAssert owner.cancelled == same, "wrong DMA owner invalidated by route " & $route
    doAssert txActiveDmaOwner == addr owner
    txActiveDmaOwner = nil
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [False, True])
def test_dma_notification_routes(tmp_path: Path, mode: str, mutation: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    helper_names = ["txlInvalidateDmaFrame", "txlInvalidateDmaAc", "txlInvalidateDmaVif",
                    "txlInvalidateDmaStation", "txlInvalidateDmaAll"]
    helpers = "".join(procedure(tx, name) for name in helper_names)
    platform = VIF_PLATFORM.replace(DMA_INVALIDATION_STUBS, "")
    platform = platform.replace("type\n", "type\n  TxDmaOwner = object\n    desc: pointer\n"
        "    vif, station, ac: uint8\n    cancelled: bool\n", 1)
    platform = platform.replace("var\n", "var\n  txActiveDmaOwner, txActiveTriggerOwner: ptr TxDmaOwner\n", 1)
    platform = platform.replace("proc hostTxDescAt", helpers + "proc hostTxDescAt", 1)
    bodies = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    for name in [
        "txlStationAdmits", "txl_frame_release", "txl_frame_cfm", "txl_cfm_push", "txlFrameConfirmPending",
        "txl_frame_evt", "txl_cfm_flush", "txl_cntrl_halt_ac", "txlDetachAc",
        "txlQueueReferencesStation", "txlQueueReferencesVif", "txlHaltVifQueues", "txlHaltStationQueues", "txlDrainRetiredPostponed",
        "txlVifIsRetiring", "txl_retire_vif", "txl_cntrl_flush_ac", "txl_retire_station",
        "txl_cntrl_push_int_force",
    ]:
        bodies += procedure(tx, name)
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    if mutation:
        bodies, count = re.subn(r"(?m)^\s+txlInvalidateDma\w+\([^\n]*\)\n", "\n", bodies)
        assert count == 9
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    source = tmp_path / "notifications.nim"
    source.write_text(platform + debug + bodies + NOTIFICATION_CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *options[mode], str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout


@pytest.mark.parametrize(("name", "notification", "first_mutation"), [
    ("txl_cntrl_init", "txlInvalidateDmaAll()", "txl_hwdesc_init()"),
    ("txl_reset", "txlInvalidateDmaAll()", "ke_evt_clear("),
    ("txl_frame_init", "txlInvalidateDmaPool()", "co_list_init("),
    ("txlDetachAc", "txlInvalidateDmaAc(ac)", "regRead("),
    ("txl_retire_vif", "txlInvalidateDmaVif(vifIdx)", "txRetiringVifMask ="),
    ("txl_retire_station", "txlInvalidateDmaStation(staIdx)", "ipcEmbEnvView()"),
    ("txl_frame_cfm", "txlInvalidateDmaFrame(param)", "noteMgmtTxConfirm("),
    ("txl_cfm_push", "txlInvalidateDmaFrame(desc)", "noteMgmtTxConfirm("),
    ("txl_frame_release", "txlInvalidateDmaFrame(param)", "txlCaptureFrameCallback("),
    ("txl_frame_evt", "txlInvalidateDmaFrame(desc)", "txlFrameLeaseToken("),
    ("txu_cntrl_cfm", "txlInvalidateDmaFrame(param)", "hostTxDescAt("),
])
def test_dma_notification_precedes_mutation(name: str, notification: str, first_mutation: str) -> None:
    filename = "tx_upper.nim" if name == "txu_cntrl_cfm" else "tx_layer.nim"
    body = procedure((FW / filename).read_text(), name)
    # Ignore prose so the assertion refers to executable ordering.
    body = "\n".join(line.split("#", 1)[0] for line in body.splitlines())
    assert body.index(notification) < body.index(first_mutation)
