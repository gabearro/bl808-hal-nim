"""Exercise production AP power-save selection against a separate state model."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
import bl808/wifi/fw_messages
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    postponed: CoList
  LinkDesc = object
    macHeader: array[24, uint8]
  TestTxFrame = object
    link: CoListHdr
    pbufAddr: uint32
    etherType: uint16
    accessCategory, vifIdx, vifType, staIdx: uint8
    postponeFlags: uint16
    linkDesc: pointer
    postponeFlag: uint8
  Sta = object
    psMode, psState, trafficFlags, instNbr, valid: uint8
    psStatus: uint32
    aid: uint16
    postponedList: CoList
  Vif = object
    vifType, psFlags: uint8
  MmTimUpdatePayload = object
    aid: uint16
    setFlag, vifIdx: uint8
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  STA_MGMT_FREE_STAS = 5
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
  MmTimUpdatePayloadSize = 4
var
  vifs: array[2, Vif]
  stas: array[7, Sta]
  contextCount: uint32
  allocated: MmTimUpdatePayload
  messages: seq[MmTimUpdatePayload]
  warnings: int
  psEnv: tuple[flags, apPending, otherPending: uint8]
  frameEnv: tuple[postponedCount: uint32]
  events: uint32
  txAllowed = true
  sent: seq[pointer]
  sentCategories: seq[uint8]
  releaseCalls: int
  frees: int
  interrupts = true
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[5, uint32]
  txActiveFlush: ptr TxFlushBatch

proc apmTxDescPsAt(p: pointer): ptr TestTxFrame = cast[ptr TestTxFrame](p)
proc hostTxDescAt(p: pointer): ptr TestTxFrame = cast[ptr TestTxFrame](p)
proc txlFrameLeaseToken(d: ptr TestTxFrame): uint32 = 0
proc txlFrameLeaseMatches(d: ptr TestTxFrame; generation: uint32): bool = true
proc wifiRamPointer(p: pointer): bool = cast[uint](p) > 4096
proc txlDrainRetiredPostponed(queue: ptr CoList) =
  doAssert false, "no retirement callback in the policy matrix"
proc hostTxLinkDescAt(p: pointer): ptr LinkDesc = cast[ptr LinkDesc](p)
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc chan_ctxt_cnt(): uint32 = contextCount
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc keEnvPsFlags(): ptr typeof(psEnv) = addr psEnv
proc txFrameEnv(): ptr typeof(frameEnv) = addr frameEnv
proc ke_evt_set(bits: uint32) = events = events or bits
proc txl_cntrl_tx_check(vif: pointer): bool = txAllowed
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =
  sent.add(p)
  sentCategories.add(ac)
  1
proc sta_mgmt_postponed_desc_release(sta: pointer; flag: uint32): uint32 =
  doAssert sta == cast[pointer](addr stas[0]) and flag == 0
  inc releaseCalls
  0
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == 47 and dest == 0 and src == 3
  doAssert size == MmTimUpdatePayloadSize
  allocated = default(MmTimUpdatePayload)
  addr allocated
proc ke_msg_send(p: pointer) = messages.add(cast[ptr MmTimUpdatePayload](p)[])
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr allocated
  inc frees
proc assert_warn(cond, file: cstring; line: int) =
  doAssert line == 377
  inc warnings
proc co_list_remove(list: ptr CoList; previous, node: ptr CoListHdr) =
  if previous == nil:
    doAssert list.first == node
    list.first = node.next
  else:
    doAssert previous.next == node
    previous.next = node.next
  if list.last == node: list.last = previous
proc co_list_pop_front(list: ptr CoList): pointer =
  let node = list.first
  if node == nil: return nil
  co_list_remove(list, nil, node)
  cast[pointer](node)
proc co_list_push_front(list: ptr CoList; node: ptr CoListHdr) =
  node.next = list.first
  if list.first == nil: list.last = node
  list.first = node
proc reset() =
  vifs = default(typeof(vifs))
  stas = default(typeof(stas))
  messages.setLen(0)
  warnings = 0
  psEnv = default(typeof(psEnv))
  frameEnv.postponedCount = 0
  events = 0
  sent.setLen(0)
  sentCategories.setLen(0)
  releaseCalls = 0
  frees = 0
  interrupts = true
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  txAllowed = true

# Independent mapping from the vendor table: BK=bit2, BE=bit3, VI=bit1, VO=bit0.
proc deliveryBit(ac: uint8): uint8 = 1'u8 shl [2, 3, 1, 0][ac]
proc eligible(ac, mask: uint8; service: uint32): bool =
  ((deliveryBit(ac) and mask) != 0) == (service == 2)
proc buildQueue(frames: var array[3, TestTxFrame]; links: var array[3, LinkDesc];
                categories: array[3, uint8]; count: int) =
  for i in 0 ..< count:
    frames[i] = TestTxFrame(accessCategory: categories[i],
                           linkDesc: addr links[i], postponeFlag: 1)
    links[i] = default(LinkDesc)
    links[i].macHeader[0] = 0x88
    links[i].macHeader[1] = (if i == 1: 0x21'u8 else: 0x01'u8)
    if i + 1 < count: frames[i].link.next = addr frames[i + 1].link
  stas[0].postponedList.first = if count == 0: nil else: addr frames[0].link
  stas[0].postponedList.last = if count == 0: nil else: addr frames[count - 1].link
proc assertQueue(frames: var array[3, TestTxFrame]; count, removed: int) =
  var node = stas[0].postponedList.first
  var last: ptr CoListHdr
  for i in 0 ..< count:
    if i == removed: continue
    doAssert node == addr frames[i].link
    last = node
    node = node.next
  doAssert node == nil and stas[0].postponedList.last == last
"""

CHECKS = r"""
# Ordinary AP power saving must still apply with zero or one channel context.
for contexts in 0'u32 .. 3'u32:
  for vifIndex in 0'u8 .. 1'u8:
    for vifType in 0'u8 .. 3'u8:
      for staIndex in [0'u8, 3, 6, 7, 255]:
        for pbuf in [0'u32, 1, 0xDEADBEEF'u32]:
          for etherType in [0'u16, 0x0800]:
            for fc in [0x00C4'u16, 0x01C4, 0x0008]:
              for sleepState in [0'u8, 1, 2]:
                for service in [0'u32, 1, 2, 3, 4, 8, 9, 10]:
                  reset()
                  contextCount = contexts
                  vifs[1 - vifIndex].vifType = if vifType == 2: 0 else: 2
                  vifs[vifIndex].vifType = vifType
                  if staIndex <= 6:
                    stas[staIndex].psMode = sleepState
                    stas[staIndex].psStatus = service
                  var link: LinkDesc
                  link.macHeader[0] = (fc and 0xFF).uint8
                  link.macHeader[1] = (fc shr 8).uint8
                  var frame = TestTxFrame(pbufAddr: pbuf, etherType: etherType,
                    vifIdx: vifIndex, staIdx: staIndex, linkDesc: addr link,
                    postponeFlags: 0x0083)
                  let ctsBypass = contexts > 1 and (pbuf == 0 or etherType == 0) and fc == 0x00C4
                  let deferFrame = not ctsBypass and vifType == 2 and staIndex <= 6 and
                                   sleepState == 1 and (service and 3) == 0
                  doAssert apm_tx_int_ps_check(addr frame) == not deferFrame
                  doAssert frame.postponeFlags == (if deferFrame: 0x1083'u16 else: 0x0083'u16)
                  doAssert messages.len == 0

# Every AC/mask/traffic-state combination, including duplicate postponement.
for ac in 0'u8 .. 3'u8:
  for mask in 0'u8 .. 15'u8:
    for traffic in 0'u8 .. 15'u8:
      for marked in [false, true]:
        reset()
        vifs[1].vifType = 2
        stas[0] = Sta(psState: mask, trafficFlags: traffic, aid: 0x1234, instNbr: 1, valid: 1)
        var frame = TestTxFrame(accessCategory: ac,
          vifIdx: 1, staIdx: 0,
          postponeFlags: (if marked: 0x1000'u16 else: 0x0003'u16))
        let delivery = (deliveryBit(ac) and mask) != 0
        let flag = if delivery: 8'u8 else: 2'u8
        let changed = marked and (traffic and flag) == 0
        let expectedMessages = if changed and (not delivery or mask == 15): 1 else: 0
        apm_tx_int_ps_postpone(addr frame, addr stas[0])
        doAssert stas[0].trafficFlags == (if marked: traffic or flag else: traffic)
        doAssert messages.len == expectedMessages
        if expectedMessages != 0:
          doAssert messages[0] == MmTimUpdatePayload(aid: 0x1234, setFlag: 1, vifIdx: 1)
        apm_tx_int_ps_postpone(addr frame, addr stas[0])
        doAssert messages.len == expectedMessages

# Enumerate queue lengths/order, delivery masks, service modes, and traffic bits.
for service in [0'u32, 1, 2, 4, 8, 9, 10]:
  for vifType in [0'u8, 2]:
    for mask in 0'u8 .. 15'u8:
      for traffic in 0'u8 .. 15'u8:
        for count in 0 .. 3:
          let combinations = 1 shl (count * 2)
          for encoded in 0 ..< combinations:
            reset()
            vifs[0].vifType = vifType
            stas[0] = Sta(psState: mask, psStatus: service, trafficFlags: traffic,
                          aid: 0x1234, instNbr: 0, valid: 1)
            var frames: array[3, TestTxFrame]
            var links: array[3, LinkDesc]
            var categories: array[3, uint8]
            for i in 0 ..< count: categories[i] = ((encoded shr (i * 2)) and 3).uint8
            buildQueue(frames, links, categories, count)
            let internalBit = if (service and 1) != 0: 2'u8 else: 8'u8
            let externalBit = if (service and 1) != 0: 1'u8 else: 4'u8
            var selected = -1
            var moreInternal = false
            if vifType == 2 and service != 0 and (traffic and internalBit) != 0:
              for i in 0 ..< count:
                if eligible(categories[i], mask, service):
                  if selected < 0: selected = i
                  else: moreInternal = true
            var blocked = 0xAA55'u32
            let result = apm_tx_int_ps_get_postpone(addr vifs[0], addr stas[0], addr blocked)
            assertQueue(frames, count, selected)
            if selected < 0:
              doAssert result == nil
              doAssert blocked == (if vifType != 2 or service == 0: 0'u32 else: 1'u32)
              doAssert stas[0].trafficFlags == traffic and messages.len == 0
              doAssert warnings == (if vifType == 2 and service != 0 and
                (traffic and internalBit) != 0: 1 else: 0)
            else:
              doAssert result == cast[pointer](addr frames[selected]) and blocked == 0xAA55'u32
              doAssert frames[selected].accessCategory == 3'u8 + ((service shr 3) and 1).uint8
              let newTraffic = if moreInternal: traffic else: traffic and not internalBit
              doAssert stas[0].trafficFlags == newTraffic
              let moreData = moreInternal or (newTraffic and externalBit) != 0
              let previousHeader = if selected == 1: 0x21'u8 else: 0x01'u8
              doAssert links[selected].macHeader[1] ==
                (if moreData: previousHeader or 0x20'u8 else: previousHeader)
              doAssert links[selected].macHeader[0] == 0x88
              let timCleared = not moreInternal and not moreData
              doAssert messages.len == (if timCleared: 1 else: 0)
              if timCleared:
                doAssert messages[0] == MmTimUpdatePayload(aid: 0x1234, setFlag: 0, vifIdx: 0)
              doAssert warnings == 0
            for i in 0 ..< count:
              if i != selected:
                doAssert frames[i].accessCategory == categories[i]
                doAssert links[i].macHeader[1] == (if i == 1: 0x21'u8 else: 0x01'u8)

# Station queue draining respects budgets and signals PS work only when pending.
for vifType in 0'u8 .. 3'u8:
  for psFlags in [0'u8, 1, 2]:
    for budget in [0'u32, 1, 2, 3, 9]:
      for ready in [false, true]:
        reset()
        txAllowed = ready
        vifs[0] = Vif(vifType: vifType, psFlags: psFlags)
        stas[0].valid = 1
        psEnv.flags = 0x80
        var frames: array[3, TestTxFrame]
        var links: array[3, LinkDesc]
        buildQueue(frames, links, [0'u8, 1, 2], 3)
        frameEnv.postponedCount = 3
        let expectedCount = if not ready: 0 elif budget == 0: 3 else: min(budget.int, 3)
        doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], budget) == expectedCount.uint32
        doAssert sent.len == expectedCount and frameEnv.postponedCount == (3 - expectedCount).uint32
        doAssert releaseCalls == 1
        doAssert events == (if psFlags != 0: 256'u32 else: 0'u32)
        doAssert psEnv.apPending == (if psFlags != 0 and vifType == 2: 1'u8 else: 0'u8)
        doAssert psEnv.otherPending == (if psFlags != 0 and vifType == 0: 1'u8 else: 0'u8)
        doAssert psEnv.flags == (if psFlags != 0 and vifType == 2: 0x82'u8
                                elif psFlags != 0 and vifType == 0: 0x81'u8 else: 0x80'u8)
        for i in 0 ..< 3:
          if i < expectedCount:
            doAssert sent[i] == cast[pointer](addr frames[i]) and sentCategories[i] == i.uint8
            doAssert frames[i].postponeFlag == 0
          else: doAssert frames[i].postponeFlag == 1

# The integrated drain uses the selected frame, not necessarily the queue head.
reset()
vifs[0].vifType = 2
stas[0] = Sta(psStatus: 2, psState: 8 or 2, trafficFlags: 8, valid: 1)
var frames: array[3, TestTxFrame]
var links: array[3, LinkDesc]
buildQueue(frames, links, [0'u8, 1, 2], 3)
frameEnv.postponedCount = 3
doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 1) == 1
doAssert sent == @[cast[pointer](addr frames[1])] and sentCategories == @[3'u8]
doAssert frames[1].postponeFlag == 0 and frameEnv.postponedCount == 2
assertQueue(frames, 3, 1)
"""


def test_apm_power_save_postponement(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    base = ROOT / "src/bl808/wifi/fw"
    apm = (base / "scan_station_ap_me.nim").read_text()
    sta = (base / "sta_management.nim").read_text()
    # The core runs with host pointer doubles; check the real packed ABI too.
    layout = (base / "layout_types.nim").read_text()
    overlay = layout.split("  ApmTxDescPsView", 1)[1].split("\n  HostTxDescView", 1)[0]
    overlay = "type\n  ApmTxDescPsView" + overlay
    checks = re.findall(r"  doAssert offsetof\(ApmTxDescPsView, [^\n]+", layout)
    abi_checks = "\nstatic:\n" + "\n".join(checks)
    identity = "type\n  ApmPsSession = object" + layout.split(
        "  ApmPsSession = object", 1
    )[1].split("\n  TxDmaOwner", 1)[0]
    table = (base / "global_state/storage.nim").read_text().split("var mac_ac2uapsd*", 1)[1].split("\n]", 1)[0]
    table = "\nvar mac_ac2uapsd*" + table + "\n]\n"
    procedures = "proc apmPsCapture" + apm.split("proc apmPsCapture", 1)[1].split(
        "proc apm_tx_int_ps_clear*", 1
    )[0]
    send = "proc sta_mgmt_send_postponed_frame*" + sta.split("proc sta_mgmt_send_postponed_frame*", 1)[1].split(
        "proc staMgmtResetEntry(", 1
    )[0]
    owners = "proc staPostponedOwner" + sta.split("proc staPostponedOwner", 1)[1].split(
        "proc staReleasePostponed(", 1
    )[0]
    source = tmp_path / "ps_postpone_test.nim"
    source.write_text(PLATFORM + identity + overlay + abi_checks + table + owners + procedures + send + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{ROOT / 'src'}",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
