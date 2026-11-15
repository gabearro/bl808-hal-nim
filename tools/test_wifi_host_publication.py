"""Exercise IPC ownership transfer and lower TX publication reentrantly."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  NUM_TX_QUEUES = 5
  WifiIpcTxDrainLimit = 16'u32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  HostTxDescView = object
    link: CoListHdr
    aggDescPtr: uint32
    aggDescStorage: array[32, uint8]
    policy, dmaLink, hwDesc, bufDesc, queueFirst: pointer
    cfmStatus, retryCount, lifetime, txFlags: uint32
    frameLen, seqPassthrough: uint16
    staIdx, vifIdx, staInfoIdx, hdrLen, secTailLen: uint8
    bufferPtrs, bufferLens: array[4, uint32]
  IpcHostTxWrapperView = object
    link: CoListHdr
    active: uint32
    txDesc: HostTxDescView
  IpcEmbEnvView = object
    hostTxList, hostTxCfmList: ptr CoList
  Hardware = object
    secondaryDescToStatusPadding, frameLen, magic: uint32
    secondaryTxHwDescPtr, status, controlFlags, payloadStart, payloadEnd: uint32
    frameLenToRetryLimitPadding, confirmStatus: uint32
    chainedThd: pointer
  Buffered = object
    txDesc: pointer
  Ac = object
    pending: CoList
  TxEnv = object
    ac: array[5, Ac]
    packetCounter: uint32
var
  wrappers: array[40, IpcHostTxWrapperView]
  hardware: array[40, Hardware]
  buffers: array[40, Buffered]
  hostList, confirmList: CoList
  env: IpcEmbEnvView
  txEnv: TxEnv
  ipcTxDispatchActive: bool
  interrupts = true
  keEvtField: uint32
  submitted, completed, allocated, fakeTransfers: seq[int]
  peerWork: seq[string]
  writes: seq[tuple[address: uint, value: uint32]]
  selectedAc, nestedAc: uint32
  nestedStage: string
  nestedFired, inSubmit, immediate, recycle, requeue: bool
  queueReads: int

proc ipc_emb_tx_evt*(ac: uint32) {.exportc, cdecl.}
proc txl_cntrl_push*(param: pointer; ac: uint8): uint8 {.exportc, cdecl.}
proc ipc_emb_txcfm*(desc: pointer) {.exportc, cdecl.}
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txSecurityCurrent(d: ptr HostTxDescView): bool = true
proc txSecurityForget(d: pointer) = discard
proc txlCaptureSession(d: ptr HostTxDescView): int = 0
proc txlSessionCurrent(i: int; d: ptr HostTxDescView): bool = true
proc txuCancelFrame(p: pointer; ac: uint8) = doAssert false
proc txl_frame_release(p: pointer; callback: bool) = doAssert false
proc indexOf(p: pointer): int =
  for i in 0 ..< wrappers.len:
    if p == cast[pointer](addr wrappers[i].txDesc): return i
  doAssert false, "unknown descriptor"
proc ipcHostTxWrapperFromDesc(d: ptr HostTxDescView): ptr IpcHostTxWrapperView =
  addr wrappers[indexOf(d)]
proc hostTxHwDescAt(p: pointer): ptr Hardware =
  for i in 0 ..< wrappers.len:
    if p == cast[pointer](addr wrappers[i].txDesc.aggDescPtr): return addr hardware[i]
  doAssert false, "unknown hardware descriptor"
proc hostTxBufferedLinkAt(p: pointer): ptr Buffered = cast[ptr Buffered](p)
proc ipcEmbEnvView(): ptr IpcEmbEnvView = addr env
proc ipcHostTxHead(e: ptr IpcEmbEnvView): ptr IpcHostTxWrapperView =
  inc queueReads
  cast[ptr IpcHostTxWrapperView](e.hostTxList.first)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc getLogFunc(offset: int): pointer = nil
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc ke_evt_set(bits: uint32) = keEvtField = keEvtField or bits
proc ke_evt_clear(bits: uint32) = keEvtField = keEvtField and not bits
proc volatileStore(p: ptr uint32; value: uint32) =
  writes.add((cast[uint](p), value))
proc utils_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc utils_list_pop_front(list: ptr CoList): ptr CoListHdr =
  result = list.first
  if result == nil: return
  list.first = result.next
  if list.first == nil: list.last = nil
  result.next = nil
proc contains(list: CoList; node: ptr CoListHdr): bool =
  var current = list.first
  var count = 0
  while current != nil:
    if current == node: return true
    inc count
    doAssert count <= wrappers.len, "list cycle"
    current = current.next
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  doAssert not interrupts
  doAssert not contains(list[], node), "duplicate TX ownership"
  utils_list_push_back(list, node)
proc txControlEnv(): ptr TxEnv = addr txEnv
proc txControlAc(ac: uint32): ptr Ac = addr txEnv.ac[ac]
proc nest(stage: string) =
  if nestedStage != stage or nestedFired: return
  nestedFired = true
  let beforeSubmitted = submitted.len
  let beforeReads = queueReads
  let enabled = interrupts
  ipc_emb_tx_evt(nestedAc)
  doAssert interrupts == enabled
  doAssert queueReads == beforeReads, "nested dispatcher read the shared queue"
  doAssert submitted.len == beforeSubmitted, "nested dispatcher submitted work"
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-NIMFW] ipc_tx_evt ": nest("entry")
  elif s == "[WIFI-NIMFW] ipc_txd ": nest("descriptor")
  elif s == "[WIFI-NIMFW] txl_push_eapol ": nest("lower")
proc txlPrepareBuffer(p: pointer; ac, flags: uint32): pointer =
  doAssert not interrupts and flags == 0
  let i = indexOf(p)
  allocated.add(i)
  nest("allocation")
  addr buffers[i]
proc txlEnqueuePrepared(p, linkPtr: pointer; ac: uint32) =
  doAssert not interrupts
  if hostTxDescAt(p).queueFirst == nil: fakeTransfers.add(indexOf(p))
proc txlBuildBufferThd(p: pointer): bool =
  nest("header")
  true
proc td_pck_ind(vif, sta: uint8; direction: uint32) =
  doAssert not interrupts
  doAssert vif == 1 and sta == 3 and direction == 0
  peerWork.add("traffic")
proc ps_check_tx_frame(sta, tid: uint8): bool =
  doAssert not interrupts and sta == 3 and tid == 5
  peerWork.add("ps")
proc txl_payload_handle_backup(p: pointer) =
  doAssert not interrupts and p == nil
  let node = txEnv.ac[0].pending.last
  doAssert node != nil, "DMA started before software queue publication"
  let i = indexOf(node)
  doAssert wrappers[i].active == 1, "DMA started before host ownership transfer"
  doAssert not contains(hostList, addr wrappers[i].link), "wrapper still in host queue"
  doAssert txEnv.packetCounter == submitted.len.uint32 - completed.len.uint32,
    "DMA started before packet accounting"
  doAssert peerWork.len == submitted.len * 2, "peer work follows DMA publication"
  nest("dma")
  if immediate:
    doAssert utils_list_pop_front(addr txEnv.ac[0].pending) == node
    dec txEnv.packetCounter
    wrappers[i].active = 0
    completed.add(i)
    ipc_emb_txcfm(addr wrappers[i].txDesc)
    if recycle:
      doAssert utils_list_pop_front(addr confirmList) == addr wrappers[i].link
      # A completed wrapper is no longer the firmware's writable memory.
      wrappers[i].active = 0xAABBCCDD'u32
      wrappers[i].txDesc.vifIdx = 255
      wrappers[i].txDesc.staInfoIdx = 255
      wrappers[i].txDesc.staIdx = 255
      if requeue and completed.len == 1:
        wrappers[i].txDesc.frameLen = 0x8E88
        wrappers[i].txDesc.vifIdx = 1
        wrappers[i].txDesc.staInfoIdx = 3
        wrappers[i].txDesc.staIdx = 5
        utils_list_push_back(addr hostList, addr wrappers[i].link)
proc txu_cntrl_push(p: pointer; ac: uint8): bool =
  doAssert not interrupts and ac == 0
  doAssert not inSubmit, "simultaneous host consumer"
  inSubmit = true
  defer: inSubmit = false
  let i = indexOf(p)
  doAssert wrappers[i].active == 1
  doAssert not contains(hostList, addr wrappers[i].link)
  submitted.add(i)
  result = txl_cntrl_push(p, ac) != 0
"""

CHECKS = r"""
proc reset(count: int; payload: bool) =
  wrappers = default(typeof(wrappers))
  hardware = default(typeof(hardware))
  buffers = default(typeof(buffers))
  txEnv = default(TxEnv)
  hostList = default(CoList)
  confirmList = default(CoList)
  env.hostTxList = addr hostList
  env.hostTxCfmList = addr confirmList
  submitted.setLen(0)
  completed.setLen(0)
  allocated.setLen(0)
  fakeTransfers.setLen(0)
  peerWork.setLen(0)
  writes.setLen(0)
  keEvtField = 0
  ipcTxDispatchActive = false
  interrupts = true
  nestedFired = false
  inSubmit = false
  requeue = false
  queueReads = 0
  for i in 0 ..< count:
    wrappers[i].txDesc.frameLen = 0x8E88
    wrappers[i].txDesc.vifIdx = 1
    wrappers[i].txDesc.staInfoIdx = 3
    wrappers[i].txDesc.staIdx = 5
    wrappers[i].txDesc.hdrLen = 26
    wrappers[i].txDesc.seqPassthrough = 100
    wrappers[i].txDesc.bufDesc = addr buffers[i]
    if payload: wrappers[i].txDesc.queueFirst = cast[pointer](1)
    utils_list_push_back(addr hostList, addr wrappers[i].link)

for ac in 0'u32 .. 4:
  selectedAc = ac
  for stage in ["entry", "descriptor", "lower", "allocation", "header", "dma"]:
    nestedStage = stage
    for nested in [0'u32, 4'u32]:
      nestedAc = nested
      for complete in [false, true]:
        for reuse in [false, true]:
          if reuse and not complete: continue
          for payload in [false, true]:
            for count in [0, 1, 2, 16, 17, 33]:
              reset(count, payload)
              immediate = complete
              recycle = reuse
              var calls = 0
              while hostList.first != nil or calls == 0:
                let before = submitted.len
                ipc_emb_tx_evt(ac)
                inc calls
                doAssert interrupts and not ipcTxDispatchActive
                doAssert submitted.len - before <= 16
                if hostList.first != nil:
                  doAssert (keEvtField and (0x200'u32 shl ac)) != 0
                # The rearmed beacon event itself is a data-flow-control bit.
                # Model its scheduler service before retrying a parked AC.
                keEvtField = 0
                doAssert calls <= 4
              doAssert submitted.len == count
              for i in 0 ..< count:
                doAssert submitted[i] == i
                if complete: doAssert completed[i] == i
                doAssert wrappers[i].active ==
                  (if reuse: 0xAABBCCDD'u32 elif complete: 0'u32 else: 1'u32)
              doAssert txEnv.packetCounter == (if complete: 0'u32 else: count.uint32)
              doAssert allocated.len == (if payload: count else: 0)
              doAssert fakeTransfers.len == (if payload: 0 else: count)
              let stageApplies = stage == "entry" or (count != 0 and
                (stage notin ["allocation", "header"] or payload))
              doAssert nestedFired == stageApplies
              if complete and not reuse and count != 0:
                doAssert confirmList.first == addr wrappers[0].link
                doAssert confirmList.last == addr wrappers[count - 1].link
              else:
                doAssert confirmList.first == nil

# A parked queue remains host-owned, and can be retried without duplicates.
for ac in 0'u32 .. 4:
  reset(2, true)
  nestedStage = ""
  immediate = false
  recycle = false
  keEvtField = 0x2000 # one of the flow-control bits
  ipc_emb_tx_evt(ac)
  if ac != 4:
    doAssert submitted.len == 0 and wrappers[0].active == 0
    doAssert hostList.first == addr wrappers[0].link
    keEvtField = 0
    ipc_emb_tx_evt(ac)
  doAssert submitted == @[0, 1] and not ipcTxDispatchActive

# Empty/invalid invocations preserve disabled as well as enabled IRQ states.
for ac in [0'u32, 4, 5, 31, 255, high(uint32)]:
  for enabled in [false, true]:
    reset(0, true)
    nestedStage = ""
    interrupts = enabled
    ipc_emb_tx_evt(ac)
    doAssert interrupts == enabled and not ipcTxDispatchActive

# A host can recycle and requeue the exact wrapper during synchronous completion.
for enabled in [false, true]:
  reset(2, true)
  immediate = true
  recycle = true
  requeue = true
  nestedStage = "dma"
  nestedAc = 0
  interrupts = enabled
  ipc_emb_tx_evt(0)
  doAssert submitted == @[0, 1, 0] and completed == submitted
  doAssert hostList.first == nil and confirmList.first == nil
  doAssert txEnv.packetCounter == 0 and interrupts == enabled
  doAssert not ipcTxDispatchActive
  doAssert wrappers[0].active == 0xAABBCCDD'u32
  doAssert wrappers[1].active == 0xAABBCCDD'u32
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "late_active", "late_pop", "reentry", "late_count", "late_queue"])
def test_host_publication(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    ipc = (FW / "ipc_embedded.nim").read_text()
    body = procedure(ipc, "ipc_emb_tx_evt") + procedure(ipc, "ipc_emb_txcfm")
    body += procedure((FW / "tx_layer.nim").read_text(), "txl_cntrl_push")
    if mutation in ["late_active", "late_pop"]:
        line = ("      wrapper.active = 1\n" if mutation == "late_active"
                else "      discard utils_list_pop_front(env.hostTxList)\n")
        assert body.count(line) == 1
        body = body.replace(line, "")
        anchor = "      discard txu_cntrl_push(txParam, 0'u8)\n"
        assert body.count(anchor) == 1
        body = body.replace(anchor, anchor + line)
    elif mutation == "reentry":
        start = body.index("  if ipcTxDispatchActive:\n")
        end = body.index("  ipcTxDispatchActive = true\n", start)
        body = body[:start] + body[end:]
    elif mutation in ["late_count", "late_queue"]:
        line = ("  txCtrl.packetCounter = txCtrl.packetCounter + 1\n"
                if mutation == "late_count" else
                "  co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))\n")
        assert body.count(line) == 1
        body = body.replace(line, "").replace(
            "  txl_payload_handle_backup(nil)\n", "  txl_payload_handle_backup(nil)\n" + line)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    source = tmp_path / "host_publication.nim"
    source.write_text(PLATFORM + debug + body + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
