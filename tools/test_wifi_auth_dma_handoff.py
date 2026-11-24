"""Reused internal auth TX slot, from normal push through the first AC_VO doorbell.

Vendor oracle (symbol-relative offsets in the pinned libwifi_bl808.a):
  txl_frame.o:txl_frame_push +0x72..0x80 selects hw+56 = 0x200 for
  unicast non-control; +0x58 clears hw+64 before the +0x6a push_int call.
  txl_cntrl.o:txl_cntrl_push_int +0x70/+0x8e/+0xa4 transfers, queues, drains.
  txl_cntrl.o:txl_payload_handle_backup +0x8c/+0x8e branches to +0x106
  for nil desc+8, skipping header/MIC and the +0xee..0x102 policy stores.
  The idle AC_VO path publishes the head and triggers DMA at +0x220/+0x224.

Also check a stationless scan probe and keyed-station Null frames against
production key admission. This is a host test: there is no AP or radio.
"""

import hashlib
from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_backup import PLATFORM


ORACLE_SHA256 = "6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7"


def host_platform() -> str:
    # Keep the shared backup fixture's host-width links and MMIO doubles,
    # but use the real packed 52-byte layout for the DMA policy snapshot.
    layout = (FW / "layout_types.nim").read_text()
    start = layout.index("  HostTxRateTemplateView {.packed.}")
    end = layout.index("  TxBufferControlView {.packed.}", start)
    platform = (PLATFORM[:PLATFORM.index("  HostTxRateTemplateView = object")]
                + layout[start:end] + PLATFORM[PLATFORM.index("  HostTxLinkDescView = object"):])
    return platform.replace(procedure(platform, "txSecurityCurrent"), "", 1).replace(
        "  Vif = object", """  ChannelContext = object
    status, contextIndexOrMarker, altIdx: uint8
  Vif = object
    chanCtxt: ptr ChannelContext
    vifIdx: uint8""").replace("  HostTxDescView = object", """  HostTxDescView = object
    postponeFlag, usedFlag: uint8
    pendingMacTime: uint32""").replace(
        procedure(platform, "machwTxTrigger"),
        "proc machwTxTrigger(mask: uint32)\n",
    )


READY_PATH = r"""
var
  channel: tuple[currentCtxt, scheduledCtxt: ptr ChannelContext; flags, ctxtCount: uint8]
  peer: tuple[postponedList: CoList]
  frameEnv: tuple[postponedCount: uint32]
proc chanEnvView(): auto = addr channel
proc chanCtxtAt(p: ptr ChannelContext): auto = p
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc txlFrameLeaseToken(d: ptr HostTxDescView): uint32 = 1
proc txlFrameLeaseMatches(d: ptr HostTxDescView; token: uint32): bool =
  d == (addr descs[0]) and token == 1
proc txlStationAdmits(d: ptr HostTxDescView): bool = d == (addr descs[0])
proc txlFramePreparationCurrent(d: ptr HostTxDescView; id: int; token: uint32): bool =
  txlFrameLeaseMatches(d, token) and txlSessionCurrent(id, d)
proc txl_cntrl_tx_check(p: pointer): bool = p == (addr vifs[0])
proc chan_is_on_channel(p: pointer): bool = p == (addr vifs[0])
proc apm_tx_int_ps_check(p: pointer): bool = p == (addr descs[0])
proc staInfoForIdx(idx: uint8): auto = addr peer
proc txFrameEnv(): auto = addr frameEnv
proc macTimeNow(): uint32 = 0
proc apm_tx_int_ps_postpone(p, sta: pointer) = doAssert false, "unexpected postpone"
proc assert_err(condition, file: cstring; line: cint) = doAssert false, $condition

# The descriptor contains RV32 addresses. Resolve only this fixture's MAC buffer.
proc macDataFrameAt(p: pointer): ptr MacDataFrameHeaderView =
  doAssert pointerAddrU32(p) == pointerAddrU32(addr links[0].macHeader[0])
  cast[ptr MacDataFrameHeaderView](addr links[0].macHeader[0])
"""

SECURITY = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
type
  VifKeySlotView = object
    installed, cipherType, staIdx, keyIdx: uint8
  MacQosDataFrameHeaderView {.packed.} = object
    header: MacDataFrameHeaderView
    qosCtrl: uint16
var
  rxKeyRevision: uint64
  rxKeyLastChanged: array[32, uint64]
  pairwiseKey = VifKeySlotView(installed: 1, cipherType: 2)
  hasKey = false
proc macFrameControlAt(p: pointer): ptr MacDataFrameHeaderView = macDataFrameAt(p)
proc txSecuritySelectedKey(d: ptr HostTxDescView; bip: bool): ptr VifKeySlotView =
  if hasKey and d.staInfoIdx == 0 and not bip: addr pairwiseKey
  else: nil
"""


HANDOFF = r"""
const
  Voice = 3'u8
  Auth = [0xb0'u8, 0, 0, 0,          # FC, duration
          2, 0, 0, 0, 0, 0x22,       # destination (unicast)
          2, 0, 0, 0, 0, 0x11,       # source
          2, 0, 0, 0, 0, 0x22,       # BSSID
          0x30, 0x12, 0, 0, 1, 0, 0, 0]  # seqCtrl, open system, transaction 1, success
  Policy = [0xbadcab1e'u32, 0, 1, 0, 0xffff0704'u32, 0x400, 0, 0, 0, 0x50, 0, 0, 0]
static: doAssert sizeof(HostTxRateTemplateView) == sizeof(Policy)
var expectedPolicy = Policy
var expectedRetry: uint32
var expectedFrame = Auth
var expectedLength = Auth.len.uint32
var expectedAck = 0x200'u32

proc machwTxTrigger(mask: uint32) =
  doAssert mask == 0x1000 and heads[Voice] == (addr hw[0].magic), "wrong DMA submission"
  doAssert controls[Voice].pending.first == (addr descs[0])
  doAssert descs[0].queueFirst == nil
  doAssert hw[0].confirmStatus == 0, "stale completion visible to DMA"
  doAssert hw[0].ackPolicyControl == expectedAck
  doAssert (hw[0].controlFlags and 0x100) != 0
  doAssert hw[0].payloadStart == pointerAddrU32(addr links[0].macHeader[0])
  doAssert hw[0].payloadEnd == hw[0].payloadStart + expectedLength - 1
  doAssert hw[0].frameLen == expectedLength + 4
  doAssert equalMem(addr links[0].macHeader[0], addr expectedFrame[0], expectedLength.int), "MPDU changed"
  doAssert hw[0].chainedThd == (addr links[0].rateTemplate), "policy pointer changed"
  doAssert equalMem(hw[0].chainedThd, addr expectedPolicy[0], sizeof(Policy)), "policy changed"
  doAssert hw[0].retryLimitControl == expectedRetry, "buffered retry limit copied"
  triggers.add(mask)

proc submitReusedSlot(station: uint8) =
  controls[Voice] = default(AcControl)
  queues[Voice] = default(BackupQueue)
  heads[Voice] = nil
  triggers.setLen(0)
  descs[0].bufDesc = addr links[0]
  descs[0].hwDesc = addr hw[0]
  descs[0].queueFirst = nil
  descs[0].staInfoIdx = station
  descs[0].frameLen = expectedLength.uint16
  descs[0].seqPassthrough = expectedLength.uint16
  copyMem(addr links[0].macHeader[0], addr expectedFrame[0], expectedLength.int)
  copyMem(addr links[0].rateTemplate, addr expectedPolicy[0], sizeof(Policy))
  links[0].ackPolicyControl = 0xdead0001'u32  # buffered-only trailer; must not be copied
  links[0].retryLimitControl = 0xdead0002'u32
  hw[0].magic = 0xcafebabe'u32
  hw[0].payloadStart = pointerAddrU32(addr links[0].macHeader[0])
  hw[0].payloadEnd = hw[0].payloadStart + expectedLength - 1
  hw[0].frameLen = expectedLength + 4
  hw[0].chainedThd = addr links[0].rateTemplate
  hw[0].retryLimitControl = expectedRetry
  hw[0].confirmStatus = 0x80010700'u32
  hw[0].ackPolicyControl = 0xffffffff'u32
  hw[0].controlFlags = 0
  doAssert txl_frame_push(addr descs[0], Voice) == 1
  doAssert triggers == @[0x1000'u32], "expected exactly one DMA doorbell"
  doAssert formatCalls.len == 0 and micCalls.len == 0, "buffered preparation ran"

submitReusedSlot(0)
# Nonzero retry slots distinguish preservation from clearing back to defaults.
for i in [6, 7, 8, 10, 11, 12]: expectedPolicy[i] = 0x12340000'u32 + i.uint32
expectedRetry = 0x11223344
submitReusedSlot(0)

# Broadcast scan probe: no station record or pairwise key, no ACK expected.
expectedFrame[0] = 0x40
for i in 4 .. 9: expectedFrame[i] = 0xFF
for i in 16 .. 21: expectedFrame[i] = 0xFF
expectedFrame[24 .. 29] = [0'u8, 0, 1, 2, 0x82, 0x84]
expectedAck = 0
submitReusedSlot(0xFF)

# Protected station, unprotected header-only keepalive frames through VO.
expectedFrame = Auth
expectedFrame[1] = 1
expectedAck = 0x200
hasKey = true
for (subtype, length) in [(0x48'u8, 24'u32), (0xC8'u8, 26'u32)]:
  expectedFrame[0] = subtype
  expectedLength = length
  submitReusedSlot(0)
"""


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_reused_auth_slot_at_dma_trigger(tmp_path: Path, mode: str) -> None:
    archive = ROOT / "tools/ref/libwifi_bl808.a"
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == ORACLE_SHA256
    tx = (FW / "tx_layer.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    security = (FW / "tx_security.nim").read_text()
    dma = (FW / "runtime_helpers.nim").read_text()
    bindings = security.split("proc txSecurityKeyUpdatePending", 1)[0].replace(" {.wifiCtrl.}", "")
    path = (procedure(dma, "wifiDmaStoreLink")
            + procedure(tx, "txl_payload_handle_backup")
            + procedure(tasks, "txl_int_fake_transfer")
            + procedure(tx, "txl_cntrl_push_int")
            + procedure(tx, "txlFramePushPrepared")
            + procedure(tx, "txl_frame_push"))
    debug = set(re.findall(r"\bnimFwDbg\w+", path)) - {"nimFwDbgDhcpTxFinalBreakpoint"}
    types = {"nimFwDbgProbePayRaw": "array[64, uint8]"}
    declarations = "\nvar\n" + "".join(
        f"  {name}: {types.get(name, 'uint32')}\n" for name in sorted(debug)
    )
    run_program(tmp_path, mode, host_platform() + READY_PATH + SECURITY + bindings
                + procedure(security, "txSecurityIsInternalNull")
                + procedure(security, "txSecurityCurrent") + declarations + path + HANDOFF)
